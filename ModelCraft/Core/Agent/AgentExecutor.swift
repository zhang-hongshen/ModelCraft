//
//  AgentExecutor.swift
//  ModelCraft
//
//  Created by Hongshen on 5/1/26.
//

import Foundation
import SwiftData

import MLXLMCommon
import Tokenizers

final class AgentExecutor {

    private let interactionCoordinator: UserInteractionCoordinator
    /// Nobody is present to answer questions or approve actions.
    private let isUnattended: Bool

    init(interactionCoordinator: UserInteractionCoordinator, isUnattended: Bool = false) {
        self.interactionCoordinator = interactionCoordinator
        self.isUnattended = isUnattended
    }
    
    /// Stop offering tools after this many identical tool calls in a row (same name + arguments).
    private static let maxConsecutiveIdenticalToolCalls = 3

    private static let duplicateToolCallMessage = """
        This identical tool call was blocked because it has already been attempted repeatedly. Use the existing result, change the arguments, choose another tool, or answer with the information available.
        """
    
    @MainActor
    func run(
        model: LocalModel,
        thread: Thread,
        ticket: Ticket,
        prepareMessages: @MainActor () async throws -> [MLXLMCommon.Chat.Message]
    ) async throws -> Void {
        try Task.checkCancellation()
        let project = thread.project
        // Approvals are scoped to the working folder, so changing it starts over.
        if thread.toolAuthorization.map({ $0.workingDirectory != project?.workingDirectory }) ?? true {
            thread.toolAuthorization = ToolAuthorizationContext(
                workingDirectory: project?.workingDirectory,
                threadDirectory: thread.directory)
        }
        try FileManager.default.createDirectory(
            at: thread.directory, withIntermediateDirectories: true)

        try await ProjectToolContext.$workingDirectory.withValue(project?.workingDirectory) {
            try await ProjectToolContext.$threadDirectory.withValue(thread.directory) {
                try await ProjectToolContext.$readOnlyFiles.withValue((project?.resources ?? []) + [ResourceStore.directory]) {
                    try await runLoop(
                        model: model,
                        thread: thread,
                        ticket: ticket,
                        prepareMessages: prepareMessages)
                }
            }
        }
    }

    @MainActor
    private func runLoop(
        model: LocalModel,
        thread: Thread,
        ticket: Ticket,
        prepareMessages: @MainActor () async throws -> [MLXLMCommon.Chat.Message]
    ) async throws {
        var lastSignature: String?
        var consecutiveCalls = 0
        while true {
            let messages = try await prepareMessages()
            let availableTools = ToolDefinition.allToolSchema(for: thread)
            let assistantMessage = Message(role: .assistant, thread: thread, status: .new)
            ticket.append(assistantMessage)
            ModelContainer.shared.mainContext.persist(assistantMessage)
            var pendingCalls: [(ToolCall, RejectedToolCall?)] = []
            for try await batch in try await LMService.shared.generate(
                model: model,
                messages: messages,
                tools: availableTools
            ) {
                try Task.checkCancellation()
                if let info = batch.info {
                    thread.tokenCount = info.promptTokenCount + info.generationTokenCount
                }
                let rejection = batch.rejectedToolCall
                if let toolCall = batch.toolCall ?? rejection.map(Self.recordedToolCall) {
                    pendingCalls.append((toolCall, rejection))
                } else if let chunk = batch.chunk {
                    assistantMessage.status = .generating
                    assistantMessage.content.append(chunk)
                }
            }
            assistantMessage.status = .generated
            if !pendingCalls.isEmpty && assistantMessage.content.isEmpty {
                thread.deleteMessages([assistantMessage])
            }
            try ModelContainer.shared.mainContext.save()

            for (toolCall, rejection) in pendingCalls {
                try Task.checkCancellation()
                let toolMessage = Message(
                    role: .tool, thread: thread, toolCall: toolCall, status: .generating)
                ticket.append(toolMessage)
                ModelContainer.shared.mainContext.insert(toolMessage)
                // Commit intent before a tool can cause an external side effect.
                try ModelContainer.shared.mainContext.save()

                let signature = toolCall.signature
                consecutiveCalls = signature == lastSignature ? consecutiveCalls + 1 : 1
                lastSignature = signature
                let result: (CallToolResult, MLXLMCommon.Chat.Message)
                if thread.activeTicket?.id != ticket.id {
                    let text = "This call was not executed because execution handed off to another task."
                    result = (.error(text), .tool(text))
                } else if consecutiveCalls >= Self.maxConsecutiveIdenticalToolCalls {
                    result = (.error(Self.duplicateToolCallMessage), .tool(Self.duplicateToolCallMessage))
                } else if let rejection {
                    let text = Self.rejectionMessage(rejection)
                    result = (.error(text), .tool(text))
                } else {
                    result = try await ToolExecutionProgressReporter.$imageGeneration.withValue({
                        toolMessage.content = $0.storedValue
                    }) {
                        try await ToolExecutionProgressReporter.$videoGeneration.withValue({
                            toolMessage.content = $0.storedValue
                        }) {
                            try await executeToolCall(
                                toolCall, signature: signature, thread: thread, model: model)
                        }
                    }
                }
                toolMessage.content = result.1.content
                toolMessage.toolCallResult = result.0
                toolMessage.status = result.0.isError ? .failed : .generated
                try ModelContainer.shared.mainContext.save()
            }
            if pendingCalls.isEmpty || thread.activeTicket?.id != ticket.id { return }
        }
    }

    @MainActor
    private func executeToolCall(
        _ toolCall: ToolCall,
        signature: String,
        thread: Thread,
        model: LocalModel
    ) async throws -> (CallToolResult, MLXLMCommon.Chat.Message) {
        let permissionMode = UserDefaults.standard.string(forKey: UserDefaults.toolPermissionMode)
            .flatMap(ToolPermissionMode.init(rawValue:))
            ?? UserDefaultSettings.toolPermissionMode
        if !isUnattended, permissionMode == .readOnly, !toolCall.isReadOnly {
            let message = "Read Only mode does not allow this action. Ask the user to change the permission mode if changes are needed."
            return (.error(message), .tool(message))
        }
        if toolCall.function.name == ToolNames.task {
            do {
                let output = try await toolCall.execute(with: TaskTool.task(threadID: thread.id))
                return (.success(content: [.text(TextContent(text: output.content))]), .tool(output.content))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return (.error(error), .tool(error.localizedDescription))
            }
        }
        if toolCall.function.name == ToolNames.requestUserInput {
            if isUnattended {
                let message = "This is a scheduled run and nobody is present to answer. Continue with reasonable assumptions and state them in the reply."
                return (.error(message), .tool(message))
            }
            return try await executeUserInput(toolCall, thread: thread)
        }

        let requiresApproval = toolCall.requiresUserApproval
            || (!isUnattended && permissionMode == .ask
                && toolCall.function.name == ToolNames.executeCommand)
        let isAuthorized: Bool
        if isUnattended {
            isAuthorized = thread.toolAuthorization?.allowsScheduledRun(toolCall, signature: signature) == true
        } else {
            switch permissionMode {
            case .readOnly, .ask:
                isAuthorized = false
            case .auto:
                isAuthorized = thread.toolAuthorization?.allowsAutomatically(toolCall, signature: signature) == true
            case .fullAccess:
                isAuthorized = true
            }
        }
        if requiresApproval, !isAuthorized {
            if isUnattended {
                let message = "This is a scheduled run and nobody is present to approve this action, so it was not performed. Describe what should be done in the reply instead."
                return (.error(message), .tool(message))
            }
            // A patch that cannot apply is returned to the model instead of being
            // approved by the user only to fail.
            if toolCall.function.name == ToolNames.applyPatch {
                do {
                    try FileTool.validatePatch(
                        toolCall.function.arguments["patch"]?.stringValue ?? "")
                } catch {
                    return (.error(error), .tool(error.localizedDescription))
                }
            }
            var request = toolCall.approvalRequest
            request.allowsAlways = permissionMode == .auto && !toolCall.requiresFreshApproval
            let decision = try await interactionCoordinator.requestApproval(request)
            switch decision {
            case .deny:
                let message = "The user did not allow this action."
                return (.error(message), .tool(message))
            case .allowOnce:
                break
            case .alwaysAllow:
                thread.toolAuthorization?.authorize(toolCall, signature: signature)
            }
        }

        return try await ToolExecutor.dispatch(
            toolCall,
            projectID: thread.project?.persistentModelID,
            modelID: model.id)
    }

    private static func recordedToolCall(_ rejection: RejectedToolCall) -> ToolCall {
        ToolCall(
            function: ToolCall.Function(
                name: rejection.toolName ?? "",
                arguments: [String: JSONValue]()),
            id: rejection.callID)
    }

    private static func rejectionMessage(_ rejection: RejectedToolCall) -> String {
        let name = rejection.toolName ?? ""
        switch rejection.reason {
        case .undeclaredTool:
            if ToolDefinition.deferredTools.contains(where: { ToolDefinition.toolName(of: $0) == name }) {
                return "\(name) is not loaded. Call \(ToolNames.searchTools) with \(name) as the query, then call \(name) again."
            }
            return "There is no tool named \(name). Call only tools that are available."
        case .invalidArguments:
            return "The arguments of the \(name) call were not a valid JSON object. Call it again with arguments that match its parameters."
        case .missingToolName:
            return "The tool call did not name a function. Call it again with the tool's name."
        case .malformedSyntax, .incompleteOutput, .resourceLimitExceeded:
            return "The tool call could not be parsed. Call it again as one complete, well-formed tool call."
        }
    }

    private func toolName(from schema: ToolSpec) -> String? {
        let function = schema["function"] as? [String: any Sendable]
        return function?["name"] as? String
    }

    @MainActor
    private func executeUserInput(
        _ toolCall: ToolCall,
        thread: Thread
    ) async throws -> (CallToolResult, MLXLMCommon.Chat.Message) {
        let request = try await toolCall.execute(with: UserInputTool.requestUserInput)
        let output = try await interactionCoordinator.requestUserInput(request)
        thread.toolAuthorization?.authorize(request: request, output: output)
        let data = try JSONEncoder().encode(output)
        let content = String(decoding: data, as: UTF8.self)
        var result = CallToolResult()
        result.content.append(.text(TextContent(text: content)))
        return (result, .tool(content))
    }
}

/// Stored on `Thread`, so approvals last as long as the conversation.
struct ToolAuthorizationContext: Codable {

    private struct FileScope: Codable {
        let url: URL
        let includesDescendants: Bool

        func contains(_ candidate: URL) -> Bool {
            guard includesDescendants else { return candidate == url }
            return candidate.pathComponents.starts(with: url.pathComponents)
        }
    }

    /// Files and folders the user granted.
    private var fileScopes: [FileScope] = []
    private var applicationIDs: Set<String> = []
    private var allowsScreenInteraction = false
    private var approvedToolSignatures: Set<String> = []
    let workingDirectory: URL?
    private let threadDirectory: URL

    init(workingDirectory: URL?, threadDirectory: URL) {
        self.workingDirectory = workingDirectory
        self.threadDirectory = threadDirectory
    }

    /// The working folder and the thread's folder, where automatic edits are allowed.
    private var workingScopes: [FileScope] {
        [workingDirectory, threadDirectory].compactMap { $0 }.map {
            FileScope(
                url: $0.standardizedFileURL.resolvingSymlinksInPath(),
                includesDescendants: true)
        }
    }

    func allowsAutomatically(_ toolCall: ToolCall, signature: String) -> Bool {
        guard !toolCall.requiresFreshApproval || toolCall.function.name == ToolNames.executeCommand else {
            return false
        }
        switch toolCall.function.name {
        case ToolNames.applyPatch:
            let paths = toolCall.patchFileChanges.map(\.path)
            return !paths.isEmpty && contains(paths, in: fileScopes + workingScopes)
        case ToolNames.executeCommand:
            guard let command = toolCall.function.arguments["command"]?.stringValue,
                  let targets = scopedFileCommandTargets(command, allowsRemoval: false)
            else { return false }
            return contains(targets, in: fileScopes + workingScopes)
        case ToolNames.appClick, ToolNames.appDrag, ToolNames.appType, ToolNames.appKey, ToolNames.appMenu:
            return allowsScheduledRun(toolCall, signature: signature)
        default:
            if Connector(toolName: toolCall.function.name) != nil {
                return approvedToolSignatures.contains(signature)
            }
            return true
        }
    }

    /// Scheduled runs retain their bounded file-edit authority independently of the composer.
    func allowsScheduledRun(_ toolCall: ToolCall, signature: String) -> Bool {
        let scopes = fileScopes + workingScopes
        switch toolCall.function.name {
        case ToolNames.applyPatch:
            let paths = toolCall.patchFileChanges.map(\.path)
            guard !paths.isEmpty else { return false }
            return contains(paths, in: scopes)
        case ToolNames.executeCommand:
            if approvedToolSignatures.contains(signature) {
                return true
            }
            guard let command = toolCall.function.arguments["command"]?.stringValue,
                  let targets = scopedFileCommandTargets(command)
            else {
                return false
            }
            return contains(targets, in: scopes)
        case ToolNames.runAppleScript:
            // Every script needs a fresh decision.
            return false
        case ToolNames.appClick, ToolNames.appDrag, ToolNames.appType, ToolNames.appKey, ToolNames.appMenu:
            // Approval covers one application, or any window on screen for coordinates
            // taken from a screenshot of all displays.
            guard let app = toolCall.function.arguments["app"]?.stringValue else {
                return allowsScreenInteraction
            }
            return applicationIDs.contains(app.lowercased())
        default:
            return approvedToolSignatures.contains(signature)
        }
    }

    mutating func authorize(_ toolCall: ToolCall, signature: String) {
        switch toolCall.function.name {
        case ToolNames.applyPatch:
            for path in toolCall.patchFileChanges.map(\.path) {
                appendFileScope(path: path, includesDescendants: false)
            }
        case ToolNames.appClick, ToolNames.appDrag, ToolNames.appType, ToolNames.appKey, ToolNames.appMenu:
            if let app = toolCall.function.arguments["app"]?.stringValue {
                applicationIDs.insert(app.lowercased())
            } else {
                allowsScreenInteraction = true
            }
        default:
            approvedToolSignatures.insert(signature)
        }
    }

    mutating func authorize(request: RequestUserInput, output: RequestUserInputOutput) {
        for field in request.fields where field.type == .file || field.type == .directory {
            guard let answer = output.answers.first(where: { $0.fieldID == field.id }) else {
                continue
            }
            for path in answer.values {
                appendFileScope(
                    path: path,
                    includesDescendants: field.type == .directory)
            }
        }
    }

    private mutating func appendFileScope(path: String, includesDescendants: Bool) {
        let scope = FileScope(
            url: normalizedURL(for: path),
            includesDescendants: includesDescendants)
        guard !fileScopes.contains(where: {
            $0.url == scope.url && $0.includesDescendants == scope.includesDescendants
        }) else {
            return
        }
        fileScopes.append(scope)
    }

    private func normalizedURL(for path: String) -> URL {
        URL(
            fileURLWithPath: path,
            relativeTo: workingDirectory ?? threadDirectory
        ).standardizedFileURL.resolvingSymlinksInPath()
    }

    private func contains(_ paths: [String], in scopes: [FileScope]) -> Bool {
        paths.allSatisfy { path in
            let candidate = normalizedURL(for: path)
            return scopes.contains { $0.contains(candidate) }
        }
    }

    private func scopedFileCommandTargets(_ command: String, allowsRemoval: Bool = true) -> [String]? {
        let forbiddenCharacters = CharacterSet(charactersIn: "\n\r;|&><`*?[]$~\\\"'(){}")
        guard command.rangeOfCharacter(from: forbiddenCharacters) == nil else {
            return nil
        }

        let arguments = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = arguments.first else { return nil }
        let executable = (first as NSString).lastPathComponent
        guard first == executable || first == "/bin/\(executable)" || first == "/usr/bin/\(executable)",
              (allowsRemoval ? ["mkdir", "rm", "touch"] : ["mkdir", "touch"]).contains(executable)
        else { return nil }

        let targets = arguments.dropFirst().filter { !$0.hasPrefix("-") }
        return targets.isEmpty ? nil : targets
    }
}

/// How much the agent may do without asking, chosen in the composer.
enum ToolPermissionMode: String, CaseIterable, Identifiable {
    case readOnly
    case ask
    case auto
    case fullAccess

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .readOnly: "Read Only"
        case .ask: "Ask Every Time"
        case .auto: "Auto"
        case .fullAccess: "Full Access"
        }
    }

    var systemImage: String {
        switch self {
        case .readOnly: "eye"
        case .ask: "hand.raised"
        case .auto: "bolt"
        case .fullAccess: "lock.open"
        }
    }
}
