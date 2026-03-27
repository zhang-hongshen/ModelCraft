//
//  AgentExecutor.swift
//  ModelCraft
//
//  Created by Hongshen on 5/1/26.
//

import Foundation
import SwiftData
import MLXLMCommon
import UniformTypeIdentifiers

class AgentExecutor {
    
    @MainActor
    func run(
        model: LocalModel,
        knowledgeBaseID: PersistentIdentifier?,
        chat: Chat,
        messages: [MLXLMCommon.Chat.Message]
    ) async throws -> Void {
        var availableTools =  ToolDefinition.allTools
        if let knowledgeBaseID = knowledgeBaseID {
            availableTools.append(ToolDefinition.searchRelevantDocuments(knowledgeBaseID: knowledgeBaseID).schema)
        }
        let assistantMessage = Message(role: .assistant, chat: chat, status: .new)
        ModelContainer.shared.mainContext.persist(assistantMessage)
        
        for await batch in try await LLMService.shared.generate(
            model: model, messages: messages, tools: availableTools) {
            assistantMessage.status = .generating
            
            if let toolCall = batch.toolCall {
                assistantMessage.toolCall = toolCall
                let (toolCallResult, toolMessage) = try await ToolExecutor.shared.dispath(toolCall)
                assistantMessage.toolCallResult = toolCallResult
                assistantMessage.status = .generated
                try await self.run(model: model, knowledgeBaseID: knowledgeBaseID,
                                   chat: chat, messages: messages + [LLMService.shared.toMessage(assistantMessage), toolMessage])
                break
            }
            
            if let chunk = batch.chunk {
                assistantMessage.content.append(chunk)
                print("\(chunk)", terminator: "")
            }
        }
        assistantMessage.status = .generated
    }
    
}
