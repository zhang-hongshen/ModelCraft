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
    
    /// Maximum number of tool invocations per user message (each recursion is one round).
    private static let maxToolRounds = 15
    
    /// Stop offering tools after this many identical tool calls in a row (same name + arguments).
    private static let maxConsecutiveIdenticalToolCalls = 3
    
    private static let toolCallDisabledPrompt = MLXLMCommon.Chat.Message(
        role: .system,
        content: """
        Tool use is disabled for this turn (step limit reached, or the same tool with the same arguments was repeated too many times).
        Do not call tools. Answer the user directly using the conversation and any tool results you already have.
        """
    )
    
    @MainActor
    func run(
        model: LocalModel,
        projectID: PersistentIdentifier?,
        chat: Chat,
        messages: [MLXLMCommon.Chat.Message],
        toolRound: Int = 0,
        lastToolSignature: String? = nil,
        consecutiveSameToolCalls: Int = 0
    ) async throws -> Void {
        try Task.checkCancellation()
        
        let limitReached = toolRound >= Self.maxToolRounds
        let duplicateStreak = consecutiveSameToolCalls >= Self.maxConsecutiveIdenticalToolCalls
        let toolCallDisabled = limitReached || duplicateStreak
        
        var promptMessages = messages
        var availableTools: [ToolSpec] = []
        if toolCallDisabled {
            promptMessages = messages + [Self.toolCallDisabledPrompt]
        } else {
            availableTools = ToolDefinition.allTools
            if let projectID = projectID {
                availableTools.append(SearchTool.searchRelevantDocuments(projectID: projectID).schema)
            }
        }
        
        let assistantMessage = Message(role: .assistant, chat: chat, status: .new)
        ModelContainer.shared.mainContext.persist(assistantMessage)
        
        for await batch in try await LMService.shared.generate(
            model: model, messages: promptMessages, tools: availableTools) {
            try Task.checkCancellation()
            assistantMessage.status = .generating
            
            if let toolCall = batch.toolCall {
                print("ToolCall \(toolCall)")
                assistantMessage.toolCall = toolCall
                let signature = toolSignature(toolCall)
                let newConsecutive = (signature == lastToolSignature) ? consecutiveSameToolCalls + 1 : 1
                
                let (toolCallResult, toolMessage) = try await ToolExecutor.shared.dispath(toolCall)
                assistantMessage.status = .generated
                assistantMessage.toolCallResult = toolCallResult
                try await self.run(
                    model: model,
                    projectID: projectID,
                    chat: chat,
                    messages: messages + [LMService.shared.toMessage(assistantMessage), toolMessage],
                    toolRound: toolRound + 1,
                    lastToolSignature: signature,
                    consecutiveSameToolCalls: newConsecutive
                )
                break
            }
            
            if let chunk = batch.chunk {
                assistantMessage.content.append(chunk)
            }
        }
        assistantMessage.status = .generated
    }
    
    private func toolSignature(_ toolCall: ToolCall) -> String {
        return "\(toolCall.function.name)|\(String(describing: toolCall.function.arguments))"
    }
    
}
