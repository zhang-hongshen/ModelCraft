//
//  AgentExecutor.swift
//  ModelCraft
//
//  Created by Hongshen on 5/1/26.
//

import Foundation


enum AgentStreamEvent {
    case token(String)
    case finished(String)
    case error(String)
}

class AgentExecutor {
    
    private var currentTask: Task<Void, Never>?
    
    func run<T: RandomAccessCollection>(
        model: String,
        input: String,
        history: T,
        relevantDocuments: [String],
        summary: String? = nil,
        onEvent: @escaping (AgentStreamEvent) -> Void
    ) where T.Element == Message {
        stop()
        currentTask = Task {
            let initialMessages = history + [AgentPrompt.completeTask(task: input, relevantDocuments: relevantDocuments, summary: summary)]
            
            do {
                try await executeStep(model: model, messages: initialMessages, onEvent: onEvent)
            } catch {
                onEvent(.error(error.localizedDescription))
            }
        }
    }

    private func executeStep(
        model: String,
        messages: [Message],
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
                    guard let toolCall = ToolCall(json: action) else {
                        continue
                    }
                    
                    let callToolResult =  await ToolExecutor.shared.dispatch(toolCall)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
                    var content: String {
                        do {
                            let content = try encoder.encode(callToolResult.content)
                            guard let contentString = String(data: content, encoding: .utf8) else {
                                onEvent(.error("Failed to decode UTF8 string from serialized data"))
                                return "Internal serialization failure"
                            }
                            if let isError = callToolResult.isError, isError {
                                onEvent(.error(contentString))
                            }
                            return contentString
                        } catch {
                            onEvent(.error(error.localizedDescription))
                            return error.localizedDescription
                        }
                    }
                    let observation = "<observation>\(content)</observation>"
                    onEvent(.token(observation))
                    let aiMessage = Message(role: .assistant, content: aiResponse)
                    let toolMessage = Message(role: .tool, content: observation)
                    let updatedHistory = messages + [aiMessage, toolMessage]
                    try await executeStep(model: model, messages: updatedHistory, onEvent: onEvent)
                    
                case .inTag(let name, let content):
                    if name == "action" {
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
