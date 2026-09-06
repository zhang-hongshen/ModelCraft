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
    private var authorizationContext = ToolAuthorizationContext()

    init(interactionCoordinator: UserInteractionCoordinator) {
        self.interactionCoordinator = interactionCoordinator
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
        authorizationContext = ToolAuthorizationContext(
            workingDirectory: project?.workingDirectory)

        try await ProjectToolContext.$workingDirectory.withValue(project?.workingDirectory) {
            try await ProjectToolContext.$readOnlyFiles.withValue(project?.resources ?? []) {
                try await run(
                    model: model,
                    chat: chat,
                    messages: messages,
                    projectID: project?.persistentModelID,
                    lastToolSignature: nil,
                    consecutiveSameToolCalls: 0,
                    temporarilyDisabledTool: nil)
            }
        }
    }

    @MainActor
    private func run(
        model: LocalModel,
        chat: Chat,
        messages: [MLXLMCommon.Chat.Message],
        projectID: PersistentIdentifier?,
        lastToolSignature: String?,
        consecutiveSameToolCalls: Int,
        temporarilyDisabledTool: String?
    ) async throws {
        var availableTools = ToolDefinition.allToolSchema
        if let projectID {
            availableTools.append(SearchTool.searchProject(projectID: projectID).schema)
        }
        if let temporarilyDisabledTool {
            availableTools.removeAll { toolName(from: $0) == temporarilyDisabledTool }
        }

        let assistantMessage = Message(role: .assistant, chat: chat, status: .new)
        ModelContainer.shared.mainContext.persist(assistantMessage)
        var allMessages = messages
        for await batch in try await LMService.shared.generate(
            model: model,
            messages: messages,
            tools: availableTools
        ) {
            try Task.checkCancellation()
            
            if let toolCall = batch.toolCall {
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
                    status: .generating,
                    prefillTime: batch.info?.promptTime,
                    promptTokenCount: batch.info?.promptTokenCount,
                    generationTokenCount: batch.info?.generationTokenCount)
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
                } else {
                    result = try await executeToolCall(
                        toolCall,
                        signature: signature,
                        projectID: projectID)
                }

                toolMessage.content = result.1.content
                toolMessage.toolCallResult = result.0
                toolMessage.status = result.0.isError ? .failed : .generated
                allMessages.append(result.1)
                try await run(
                    model: model,
                    chat: chat,
                    messages: allMessages,
                    projectID: projectID,
                    lastToolSignature: signature,
                    consecutiveSameToolCalls: newConsecutiveSameToolCalls,
                    temporarilyDisabledTool: duplicateCallBlocked
                        ? toolCall.function.name
                        : nil)
            } else if let chunk = batch.chunk {
                assistantMessage.status = .generating
                assistantMessage.content.append(chunk)
            }
            
            if let info = batch.info {
                assistantMessage.prefillTime = info.promptTime
                assistantMessage.promptTokenCount = info.promptTokenCount
                assistantMessage.generationTokenCount = info.generationTokenCount
            }
        }
        assistantMessage.status = .generated
        
    }

    @MainActor
    private func executeToolCall(
        _ toolCall: ToolCall,
        signature: String,
        projectID: PersistentIdentifier?
    ) async throws -> (CallToolResult, MLXLMCommon.Chat.Message) {
        if toolCall.function.name == ToolNames.requestUserInput {
            return try await executeUserInput(toolCall)
        }

        if toolCall.requiresUserApproval,
           !authorizationContext.allows(toolCall, signature: signature) {
            guard try await interactionCoordinator.requestApproval(
                toolCall.approvalRequest)
            else {
                let message = "The user did not allow this action."
                return (.error(message), .tool(message))
            }
            authorizationContext.authorize(toolCall, signature: signature)
        }

        return try await ToolExecutor.dispatch(toolCall, projectID: projectID)
    }

    private func toolName(from schema: ToolSpec) -> String? {
        let function = schema["function"] as? [String: any Sendable]
        return function?["name"] as? String
    }

    @MainActor
    private func executeUserInput(
        _ toolCall: ToolCall
    ) async throws -> (CallToolResult, MLXLMCommon.Chat.Message) {
        let request = try await toolCall.execute(with: UserInputTool.requestUserInput)
        let output = try await interactionCoordinator.requestUserInput(request)
        authorizationContext.authorize(request: request, output: output)
        let data = try JSONEncoder().encode(output)
        let content = String(decoding: data, as: UTF8.self)
        var result = CallToolResult()
        result.content.append(.text(TextContent(text: content)))
        return (result, .tool(content))
    }
}

private struct ToolAuthorizationContext {

    private struct FileScope {
        let url: URL
        let includesDescendants: Bool

        func contains(_ candidate: URL) -> Bool {
            guard includesDescendants else { return candidate == url }
            return candidate.pathComponents.starts(with: url.pathComponents)
        }
    }

    private var fileScopes: [FileScope] = []
    private var applicationIDs: Set<String> = []
    private var allowsScreenInteraction = false
    private var approvedToolSignatures: Set<String> = []
    private let workingDirectory: URL?

    init(workingDirectory: URL? = nil) {
        self.workingDirectory = workingDirectory
        if let workingDirectory {
            fileScopes.append(FileScope(
                url: workingDirectory.standardizedFileURL.resolvingSymlinksInPath(),
                includesDescendants: true))
        }
    }

    func allows(_ toolCall: ToolCall, signature: String) -> Bool {
        switch toolCall.function.name {
        case ToolNames.writeFile, ToolNames.editFile:
            guard let path = toolCall.function.arguments["path"]?.stringValue else {
                return false
            }
            let candidate = normalizedURL(for: path)
            return fileScopes.contains { $0.contains(candidate) }
        case ToolNames.clickElement, ToolNames.typeText, ToolNames.pressKey:
            guard let appID = toolCall.function.arguments["appID"]?.stringValue else {
                return false
            }
            return applicationIDs.contains(appID)
        case ToolNames.click, ToolNames.drag:
            return allowsScreenInteraction
        case ToolNames.executeCommand:
            if approvedToolSignatures.contains(signature) {
                return true
            }
            guard let command = toolCall.function.arguments["command"]?.stringValue,
                  let targets = scopedFileCommandTargets(command)
            else {
                return false
            }
            return targets.allSatisfy { target in
                let candidate = normalizedURL(for: target)
                return fileScopes.contains { $0.contains(candidate) }
            }
        default:
            return approvedToolSignatures.contains(signature)
        }
    }

    mutating func authorize(_ toolCall: ToolCall, signature: String) {
        switch toolCall.function.name {
        case ToolNames.writeFile, ToolNames.editFile:
            guard let path = toolCall.function.arguments["path"]?.stringValue else { return }
            appendFileScope(path: path, includesDescendants: false)
        case ToolNames.clickElement, ToolNames.typeText, ToolNames.pressKey:
            guard let appID = toolCall.function.arguments["appID"]?.stringValue else { return }
            applicationIDs.insert(appID)
        case ToolNames.click, ToolNames.drag:
            allowsScreenInteraction = true
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
            relativeTo: workingDirectory ?? .documentsDirectory
        ).standardizedFileURL.resolvingSymlinksInPath()
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
