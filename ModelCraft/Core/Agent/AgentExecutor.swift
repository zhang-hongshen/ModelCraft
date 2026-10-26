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
        chat: Chat,
        messages: [MLXLMCommon.Chat.Message]
    ) async throws -> Void {
        try Task.checkCancellation()
        let project = chat.project
        // Approvals are scoped to the working folder, so changing it starts over.
        if chat.toolAuthorization.map({ $0.workingDirectory != project?.workingDirectory }) ?? true {
            chat.toolAuthorization = ToolAuthorizationContext(
                workingDirectory: project?.workingDirectory,
                chatDirectory: chat.directory)
        }
        try FileManager.default.createDirectory(
            at: chat.directory, withIntermediateDirectories: true)

        try await ProjectToolContext.$workingDirectory.withValue(project?.workingDirectory) {
            try await ProjectToolContext.$chatDirectory.withValue(chat.directory) {
                try await ProjectToolContext.$readOnlyFiles.withValue(project?.resources ?? []) {
                    try await run(
                        model: model,
                        chat: chat,
                        messages: messages,
                        lastToolSignature: nil,
                        consecutiveSameToolCalls: 0)
                }
            }
        }
    }

    @MainActor
    private func run(
        model: LocalModel,
        chat: Chat,
        messages: [MLXLMCommon.Chat.Message],
        lastToolSignature: String?,
        consecutiveSameToolCalls: Int
    ) async throws {
        let availableTools = ToolDefinition.allToolSchema(for: chat)
        let assistantMessage = Message(role: .assistant, chat: chat, status: .new)
        ModelContainer.shared.mainContext.persist(assistantMessage)
        var allMessages = messages
        for try await batch in try await LMService.shared.generate(
            model: model,
            messages: messages,
            tools: availableTools
        ) {
            try Task.checkCancellation()
            
            if let info = batch.info {
                chat.tokenCount = info.promptTokenCount + info.generationTokenCount
            }
            
            // A call the parser rejected is recorded with a failed result, so the model
            // learns why instead of the call vanishing.
            let rejection = batch.rejectedToolCall
            if let toolCall = batch.toolCall ?? rejection.map(Self.recordedToolCall) {
                print("ToolCall \(toolCall)")
                if assistantMessage.content.isEmpty {
                    ModelContainer.shared.mainContext.delete(assistantMessage)
                } else {
                    allMessages.append(LMService.shared.toMessage(assistantMessage))
                }
                
                let toolMessage = Message(
                    role: .tool,
                    chat: chat,
                    toolCall: toolCall,
                    status: .generating)
                ModelContainer.shared.mainContext.persist(toolMessage)
                
                let signature = toolCall.signature
                let newConsecutiveSameToolCalls = signature == lastToolSignature
                    ? consecutiveSameToolCalls + 1
                    : 1
                let duplicateCallBlocked = newConsecutiveSameToolCalls
                    >= Self.maxConsecutiveIdenticalToolCalls
                let result: (CallToolResult, MLXLMCommon.Chat.Message)
                if duplicateCallBlocked {
                    result = (
                        .error(Self.duplicateToolCallMessage),
                        .tool(Self.duplicateToolCallMessage))
                } else if let rejection {
                    let message = Self.rejectionMessage(rejection)
                    result = (.error(message), .tool(message))
                } else {
                    // Running media tools report progress into the tool message's content,
                    // which `Message` decodes until the result arrives.
                    result = try await ToolExecutionProgressReporter.$imageGeneration.withValue({
                        toolMessage.content = $0.storedValue
                    }) {
                        try await ToolExecutionProgressReporter.$videoGeneration.withValue({
                            toolMessage.content = $0.storedValue
                        }) {
                            try await executeToolCall(
                                toolCall, signature: signature, chat: chat, model: model)
                        }
                    }
                }

                toolMessage.content = result.1.content
                toolMessage.toolCallResult = result.0
                toolMessage.status = result.0.isError ? .failed : .generated
                LMService.shared.append(toolMessage, to: &allMessages)
                try await run(
                    model: model,
                    chat: chat,
                    messages: allMessages,
                    lastToolSignature: signature,
                    consecutiveSameToolCalls: newConsecutiveSameToolCalls)
            } else if let chunk = batch.chunk {
                assistantMessage.status = .generating
                assistantMessage.content.append(chunk)
            }
        }
        assistantMessage.status = .generated
        
    }

    @MainActor
    private func executeToolCall(
        _ toolCall: ToolCall,
        signature: String,
        chat: Chat,
        model: LocalModel
    ) async throws -> (CallToolResult, MLXLMCommon.Chat.Message) {
        if toolCall.function.name == ToolNames.requestUserInput {
            if isUnattended {
                let message = "This is a scheduled run and nobody is present to answer. Continue with reasonable assumptions and state them in the reply."
                return (.error(message), .tool(message))
            }
            return try await executeUserInput(toolCall, chat: chat)
        }

        // Nobody can choose a mode for a scheduled run, so it always accepts edits only.
        let permissionMode: ToolPermissionMode = isUnattended
            ? .acceptEdits
            : UserDefaults.standard.string(forKey: UserDefaults.toolPermissionMode)
                .flatMap(ToolPermissionMode.init(rawValue:))
                ?? UserDefaultSettings.toolPermissionMode
        if toolCall.requiresUserApproval,
           chat.toolAuthorization?.allows(
            toolCall, signature: signature, mode: permissionMode) != true {
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
            let decision = try await interactionCoordinator.requestApproval(
                toolCall.approvalRequest)
            switch decision {
            case .deny:
                let message = "The user did not allow this action."
                return (.error(message), .tool(message))
            case .allowOnce:
                break
            case .alwaysAllow:
                chat.toolAuthorization?.authorize(toolCall, signature: signature)
            }
        }

        return try await ToolExecutor.dispatch(
            toolCall,
            projectID: chat.project?.persistentModelID,
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
        chat: Chat
    ) async throws -> (CallToolResult, MLXLMCommon.Chat.Message) {
        let request = try await toolCall.execute(with: UserInputTool.requestUserInput)
        let output = try await interactionCoordinator.requestUserInput(request)
        chat.toolAuthorization?.authorize(request: request, output: output)
        let data = try JSONEncoder().encode(output)
        let content = String(decoding: data, as: UTF8.self)
        var result = CallToolResult()
        result.content.append(.text(TextContent(text: content)))
        return (result, .tool(content))
    }
}

/// Stored on `Chat`, so approvals last as long as the conversation.
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
    private let chatDirectory: URL

    init(workingDirectory: URL?, chatDirectory: URL) {
        self.workingDirectory = workingDirectory
        self.chatDirectory = chatDirectory
    }

    /// The working folder and the chat's folder, where edits run without a prompt
    /// unless the mode is `.ask`.
    private var workingScopes: [FileScope] {
        [workingDirectory, chatDirectory].compactMap { $0 }.map {
            FileScope(
                url: $0.standardizedFileURL.resolvingSymlinksInPath(),
                includesDescendants: true)
        }
    }

    func allows(_ toolCall: ToolCall, signature: String, mode: ToolPermissionMode) -> Bool {
        let scopes = mode == .ask ? fileScopes : fileScopes + workingScopes
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
                  let targets = mode == .auto
                    ? namedPaths(in: command)
                    : scopedFileCommandTargets(command)
            else {
                return false
            }
            return contains(targets, in: scopes)
        case ToolNames.runAppleScript:
            // Every script needs a fresh decision.
            return false
        case _ where mode == .auto:
            return true
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
            relativeTo: workingDirectory ?? chatDirectory
        ).standardizedFileURL.resolvingSymlinksInPath()
    }

    private func contains(_ paths: [String], in scopes: [FileScope]) -> Bool {
        paths.allSatisfy { path in
            let candidate = normalizedURL(for: path)
            return scopes.contains { $0.contains(candidate) }
        }
    }

    /// The paths a command names that could leave its working directory: absolute paths
    /// and paths through `..`. Nil when the command can reach a location the text does not
    /// show, through the home directory, a variable, or a substitution.
    private func namedPaths(in command: String) -> [String]? {
        guard command.rangeOfCharacter(from: CharacterSet(charactersIn: "~$`")) == nil else {
            return nil
        }
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ";|&<>()=\"'"))
        return command.components(separatedBy: separators).filter { token in
            token != "/dev/null"
                && (token.hasPrefix("/") || token.split(separator: "/").contains(".."))
        }
    }

    private func scopedFileCommandTargets(_ command: String) -> [String]? {
        let forbiddenCharacters = CharacterSet(charactersIn: "\n\r;|&><`*?[]")
        guard command.rangeOfCharacter(from: forbiddenCharacters) == nil,
              !command.contains("$("),
              !command.contains("${")
        else {
            return nil
        }

        let arguments = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = arguments.first else { return nil }
        let executable = (first as NSString).lastPathComponent
        guard ["mkdir", "rm", "touch"].contains(executable) else { return nil }

        let targets = arguments.dropFirst().filter { !$0.hasPrefix("-") }.map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return targets.isEmpty ? nil : targets
    }
}

/// How much the agent may do without asking, chosen in the composer.
enum ToolPermissionMode: String, CaseIterable, Identifiable {
    /// Only what the user allowed in the conversation runs without a prompt.
    case ask
    /// Also file edits inside the working folder.
    case acceptEdits
    /// Every tool except `run_applescript`, while the paths it names stay inside the
    /// working folder or what the user allowed.
    case auto

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .ask: "Ask"
        case .acceptEdits: "Accept Edits"
        case .auto: "Auto"
        }
    }

    var systemImage: String {
        switch self {
        case .ask: "hand.raised"
        case .acceptEdits: "pencil"
        case .auto: "bolt"
        }
    }
}
