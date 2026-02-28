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
        model: LMModel,
        knowledgeBaseID: PersistentIdentifier?,
        chat: Chat,
        message: Message
    ) async throws -> Void {
        
        let history = Array(chat.sortedMessages.suffix(from: chat.lastSummaryIndex))
        var messages = history + [AgentPrompt.completeTask(task: message.content, summary: chat.summary)]
        
        while(true) {
            var availableTools =  ToolDefinition.allTools
            if let knowledgeBaseID = knowledgeBaseID {
                availableTools.append(ToolDefinition.createSearchRelevantDocuments(knowledgeBaseID: knowledgeBaseID).schema)
            }
            let assistantMessage = Message(role: .assistant, chat: chat, status: .new)
            ModelContainer.shared.mainContext.persist(assistantMessage)
            var isToolCall = false
            
            for await batch in try await MLXService.shared.generate(
                model: model, messages: messages, tools: availableTools) {
                assistantMessage.status = .generating
                
                if let toolCall = batch.toolCall {
                    isToolCall = true
                    let toolResult = try await handleToolCall(toolCall)
                    let data = try? JSONEncoder().encode(toolCall)
                    assistantMessage._toolCall = String(data: data ?? Data(), encoding: .utf8)
                    print("Tool Call \(assistantMessage._toolCall)")
                    let toolMessage = Message(role: .tool, chat: chat, content: toolResult, status: .generated)
                    ModelContainer.shared.mainContext.persist(toolMessage)
                    break
                }
                
                if let chunk = batch.chunk {
                    isToolCall = false
                    assistantMessage.content.append(chunk)
                    print("\(chunk)", terminator: "")
                }
            }
            
            assistantMessage.status = .generated
            if(!isToolCall) {
                break
            }
            messages = Array(chat.sortedMessages.suffix(from: chat.lastSummaryIndex))
        }
        
    }
    
    private func handleToolCall(_ toolCall: ToolCall) async throws -> String {
        switch toolCall.function.name {
        case ToolNames.readFromFile:
            let result = try await toolCall.execute(with: ToolDefinition.readFromFile)
            return result.toolResult
        case ToolNames.writeToFile:
            let result = try await toolCall.execute(with: ToolDefinition.writeToFile)
            return result.toolResult
        case ToolNames.executeCommand:
            let result = try await toolCall.execute(with: ToolDefinition.executeCommand)
            return result.toolResult
        case ToolNames.searchMap:
            let result = try await toolCall.execute(with: ToolDefinition.searchMap)
            return result.toolResult
        case ToolNames.captureScreen:
            let result = try await toolCall.execute(with: ToolDefinition.captureScreen)
            return result.toolResult
        case ToolNames.click:
            let result = try await toolCall.execute(with: ToolDefinition.click)
            return result.toolResult
        case ToolNames.move:
            let result = try await toolCall.execute(with: ToolDefinition.move)
            return result.toolResult
        default:
            return "Unknown tool: \(toolCall.function.name)"
        }
    }
}



