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
        projectID: PersistentIdentifier?,
        chat: Chat,
        messages: [MLXLMCommon.Chat.Message]
    ) async throws -> Void {
        var availableTools =  ToolDefinition.allTools
        if let projectID = projectID {
            availableTools.append(SearchTool.searchRelevantDocuments(projectID: projectID).schema)
        }
        let assistantMessage = Message(role: .assistant, chat: chat, status: .new)
        ModelContainer.shared.mainContext.persist(assistantMessage)
        
        for await batch in try await LMService.shared.generate(
            model: model, messages: messages, tools: availableTools) {
            assistantMessage.status = .generating
            
            if let toolCall = batch.toolCall {
                print("ToolCall \(toolCall)")
                assistantMessage.toolCall = toolCall
                let (toolCallResult, toolMessage) = try await ToolExecutor.shared.dispath(toolCall)
                assistantMessage.status = .generated
                assistantMessage.toolCallResult = toolCallResult
                try await self.run(model: model, projectID: projectID,
                                   chat: chat, messages: messages + [LMService.shared.toMessage(assistantMessage), toolMessage])
                break
            }
            
            if let chunk = batch.chunk {
                assistantMessage.content.append(chunk)
            }
        }
        assistantMessage.status = .generated
    }
    
}
