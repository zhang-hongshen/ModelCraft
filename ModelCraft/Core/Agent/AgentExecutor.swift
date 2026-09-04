//
//  AgentExecutor.swift
//  ModelCraft
//
//  Created by Hongshen on 5/1/26.
//

import Foundation
import SwiftData
import UniformTypeIdentifiers

import MLXLMCommon
import Tokenizers

class AgentExecutor {

    typealias GenerationProvider = @MainActor (
        LocalModel,
        [MLXLMCommon.Chat.Message],
        [ToolSpec]
    ) async throws -> AsyncStream<Generation>

    typealias ToolDispatcher = @MainActor (
        ToolCall
    ) async throws -> (CallToolResult, MLXLMCommon.Chat.Message)

    typealias DecisionProvider = @MainActor (
        RequestDecisionInput
    ) async throws -> RequestDecisionOutput

    typealias GenerationInfoHandler = @MainActor (
        GenerateCompletionInfo
    ) -> Void

    private let generationProvider: GenerationProvider
    private let toolDispatcher: ToolDispatcher
    private let decisionProvider: DecisionProvider

    init(
        generationProvider: @escaping GenerationProvider = { model, messages, tools in
            try await LMService.shared.generate(
                model: model,
                messages: messages,
                tools: tools)
        },
        toolDispatcher: @escaping ToolDispatcher = { toolCall in
            try await ToolExecutor.shared.dispath(toolCall)
        },
        decisionProvider: @escaping DecisionProvider = { _ in
            throw AgentExecutorError.decisionProviderUnavailable
        }
    ) {
        self.generationProvider = generationProvider
        self.toolDispatcher = toolDispatcher
        self.decisionProvider = decisionProvider
    }
    
    /// Maximum number of tool invocations per user message (each recursion is one round).
    private static let maxToolRounds = 15
    
    /// Stop offering tools after this many identical tool calls in a row (same name + arguments).
    private static let maxConsecutiveIdenticalToolCalls = 3

    private static let duplicateToolCallMessage = """
        This identical tool call was blocked because it has already been attempted repeatedly. Use the existing result, change the arguments, choose another tool, or answer with the information available.
        """
    
    @MainActor
    func run(
        model: LocalModel,
        projectID: PersistentIdentifier?,
        chat: Chat,
        messages: [MLXLMCommon.Chat.Message],
        toolRound: Int = 0,
        lastToolSignature: String? = nil,
        consecutiveSameToolCalls: Int = 0,
        temporarilyDisabledTool: String? = nil,
        generationInfoHandler: GenerationInfoHandler? = nil
    ) async throws -> Void {
        try Task.checkCancellation()

        if toolRound >= Self.maxToolRounds {
            let limitMessage = Message(
                role: .assistant,
                chat: chat,
                content: "Tool calling stopped after reaching the \(Self.maxToolRounds)-step limit.",
                status: .failed
            )
            ModelContainer.shared.mainContext.persist(limitMessage)
            return
        }

        var availableTools = ToolDefinition.allToolSchema
        if let projectID = projectID {
            availableTools.append(SearchTool.searchRelevantDocuments(projectID: projectID).schema)
        }
        if let temporarilyDisabledTool {
            availableTools.removeAll { toolName(from: $0) == temporarilyDisabledTool }
        }

        let assistantMessage = Message(role: .assistant, chat: chat, status: .generating)
        ModelContainer.shared.mainContext.persist(assistantMessage)
        var isAssistantMessagePersisted = true
        var persistedToolMessage: Message?

        var nextTurn: (
            toolCall: ToolCall,
            toolRound: Int,
            lastToolSignature: String?,
            consecutiveSameToolCalls: Int
        )?

        do {
            for await batch in try await generationProvider(
                model, messages, availableTools) {
                try Task.checkCancellation()
                if let toolCall = batch.toolCall {
                    print("ToolCall \(toolCall)")
                    let signature = toolSignature(toolCall)
                    let newConsecutive = (signature == lastToolSignature) ? consecutiveSameToolCalls + 1 : 1

                    // Do not dispatch while the generation stream is active.
                    // The LMService lease is held until the stream is
                    // terminated; a model-backed tool would otherwise wait
                    // for this lease while this turn waits for the tool
                    // result.
                    nextTurn = (
                        toolCall: toolCall,
                        toolRound: toolRound + 1,
                        lastToolSignature: signature,
                        consecutiveSameToolCalls: newConsecutive
                    )
                    continue
                }

                if let chunk = batch.chunk {
                    assistantMessage.content.append(chunk)
                }

                if let info = batch.info {
                    assistantMessage.prefillTime = info.promptTime
                    assistantMessage.tokensPerSecond = info.tokensPerSecond
                    generationInfoHandler?(info)
                }
            }
            assistantMessage.status = .generated

            if let nextTurn {
                try Task.checkCancellation()
                let protocolAssistantMessage = LMService.shared.toMessage(assistantMessage)

                if assistantMessage.content.isEmpty {
                    ModelContainer.shared.mainContext.delete(assistantMessage)
                    isAssistantMessagePersisted = false
                }

                let toolStorageMessage = Message(
                    role: .tool,
                    chat: chat,
                    toolCall: nextTurn.toolCall,
                    status: .generating
                )
                persistedToolMessage = toolStorageMessage
                ModelContainer.shared.mainContext.persist(toolStorageMessage)

                let duplicateCallBlocked = nextTurn.consecutiveSameToolCalls
                    >= Self.maxConsecutiveIdenticalToolCalls
                let executionResult: (CallToolResult, MLXLMCommon.Chat.Message)
                if duplicateCallBlocked {
                    executionResult = (
                        .error(Self.duplicateToolCallMessage),
                        .tool(Self.duplicateToolCallMessage)
                    )
                } else if nextTurn.toolCall.function.name == ToolNames.requestDecision {
                    executionResult = try await executeDecision(nextTurn.toolCall)
                } else if nextTurn.toolCall.function.name == ToolNames.searchRelevantDocuments,
                          let projectID {
                    executionResult = try await executeDocumentSearch(
                        nextTurn.toolCall,
                        projectID: projectID)
                } else {
                    executionResult = try await toolDispatcher(nextTurn.toolCall)
                }
                let (toolCallResult, protocolToolMessage) = executionResult
                toolStorageMessage.content = protocolToolMessage.content
                toolStorageMessage.toolCallResult = toolCallResult
                toolStorageMessage.status = duplicateCallBlocked ? .failed : .generated
                try Task.checkCancellation()
                try await self.run(
                    model: model,
                    projectID: projectID,
                    chat: chat,
                    messages: messages
                        + [protocolAssistantMessage, protocolToolMessage],
                    toolRound: nextTurn.toolRound,
                    lastToolSignature: nextTurn.lastToolSignature,
                    consecutiveSameToolCalls: nextTurn.consecutiveSameToolCalls,
                    temporarilyDisabledTool: duplicateCallBlocked
                        ? nextTurn.toolCall.function.name
                        : nil,
                    generationInfoHandler: generationInfoHandler)
            }
        } catch is CancellationError {
            // Stop/cancel leaves the partial answer visible instead of
            // turning it into a permanent spinner in the chat UI.
            if let persistedToolMessage,
               persistedToolMessage.toolCallResult == nil {
                persistedToolMessage.toolCallResult = .error("Cancelled")
                persistedToolMessage.status = .generated
            }
            if isAssistantMessagePersisted && assistantMessage.status == .generating {
                assistantMessage.status = .generated
            }
            throw CancellationError()
        } catch {
            if let persistedToolMessage,
               persistedToolMessage.toolCallResult == nil {
                let description = error.localizedDescription
                persistedToolMessage.content = description.isEmpty
                    ? "Generation failed"
                    : description
                persistedToolMessage.toolCallResult = .error(persistedToolMessage.content)
                persistedToolMessage.status = .failed
            } else if isAssistantMessagePersisted {
                assistantMessage.status = .failed
                if assistantMessage.content.isEmpty {
                    let description = error.localizedDescription
                    assistantMessage.content = description.isEmpty
                        ? "Generation failed"
                        : description
                }
            }
            throw error
        }
    }
    
    private func toolSignature(_ toolCall: ToolCall) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let arguments = (try? encoder.encode(toolCall.function.arguments))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? String(describing: toolCall.function.arguments)
        return "\(toolCall.function.name)|\(arguments)"
    }

    private func toolName(from schema: ToolSpec) -> String? {
        let function = schema["function"] as? [String: any Sendable]
        return function?["name"] as? String
    }

    @MainActor
    private func executeDecision(
        _ toolCall: ToolCall
    ) async throws -> (CallToolResult, MLXLMCommon.Chat.Message) {
        let request = try await toolCall.execute(with: DecisionTool.requestDecision)
        let output = try await decisionProvider(request)
        let data = try JSONEncoder().encode(output)
        let content = String(decoding: data, as: UTF8.self)
        var result = CallToolResult()
        result.content.append(.text(TextContent(text: content)))
        return (result, .tool(content))
    }

    @MainActor
    private func executeDocumentSearch(
        _ toolCall: ToolCall,
        projectID: PersistentIdentifier
    ) async throws -> (CallToolResult, MLXLMCommon.Chat.Message) {
        let output = try await toolCall.execute(
            with: SearchTool.searchRelevantDocuments(projectID: projectID))
        var result = CallToolResult()
        result.content.append(.text(TextContent(text: output.toolResult)))
        return (result, .tool(output.toolResult))
    }
    
}

enum AgentExecutorError: Error {
    case decisionProviderUnavailable
}
