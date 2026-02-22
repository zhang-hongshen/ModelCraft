//
//  AgentExecutor.swift
//  ModelCraft
//
//  Created by Hongshen on 5/1/26.
//

import Foundation
import SwiftData
import UniformTypeIdentifiers

class AgentExecutor {
    
    private var currentTask: Task<Void, Never>?
    
    func run(
        model: String,
        input: String,
        history: [Message],
        knowledgeBaseID: PersistentIdentifier?,
        summary: String? = nil,
        onEvent: @escaping (AgentStreamEvent) -> Void
    ) {
        stop()
        currentTask = Task {
            let initialMessages = history + [AgentPrompt.completeTask(task: input, summary: summary)]
            do {
                try await executeStep(model: model, messages: initialMessages,
                                      knowledgeBaseID: knowledgeBaseID, onEvent: onEvent)
            } catch {
                onEvent(.error(error.localizedDescription))
            }
        }
    }

    private func executeStep(
        model: String,
        messages: [Message],
        knowledgeBaseID: PersistentIdentifier?,
        onEvent: @escaping (AgentStreamEvent) -> Void
    ) async throws {
        
        var action = ""
        var aiResponse = ""
        let parser = TagStreamParser()
        for try await response in OllamaService.shared.chat(
            model: model,
            messages: messages.compactMap(OllamaService.toChatRequestMessage)
        ) {
            guard let token = response.message?.content else { return }
            print(token)
            onEvent(.token(token))
            aiResponse += token
            for event in parser.feed(token) {
                switch event {
                case .outside:
                    if action.isEmpty {
                        continue
                    }
                    guard var toolCall = ToolCall(json: action) else {
                        continue
                    }
                    if toolCall.tool == .searchRelevantDocuments, let id = knowledgeBaseID {
                        toolCall.parameters["knowledge_base_id"] = .data(mimeType: UTType.json.preferredMIMEType, try JSONEncoder().encode(id))
                    }
                    
                    let callToolResult =  await ToolExecutor.shared.dispatch(toolCall)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
                    guard let observation = String(data: try encoder.encode(callToolResult), encoding: .utf8) else {
                        onEvent(.error("Failed to encode Observation as UTF8"))
                        return
                    }

                    let observationMsg = "<observation>\(observation)</observation>"
                    onEvent(.token(observationMsg))
                    let aiMessage = Message(role: .assistant, content: aiResponse + observationMsg)
                    let updatedHistory = messages + [aiMessage]
                    try await executeStep(model: model, messages: updatedHistory,
                                          knowledgeBaseID: knowledgeBaseID, onEvent: onEvent)
                    
                case .inTag(let tag, let content):
                    if tag == "action" {
                        action += content
                    }
                }
            }
            
            if response.done {
                onEvent(.finished(token))
            }
        }
    }
    
    func stop() {
        currentTask?.cancel()
        currentTask = nil
    }
}
