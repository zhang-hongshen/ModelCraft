//
//  AgentExecutor.swift
//  ModelCraft
//
//  Created by Hongshen on 5/1/26.
//

import Combine


enum AgentStreamEvent {
    case token(String)
    case finished(String)
    case error(Error)
}

class AgentExecutor {
    private var cancellable: AnyCancellable?
    
    func run<T: RandomAccessCollection>(
        model: String,
        input: String,
        history: T,
        relevantDocuments: [String],
        summary: String? = nil,
        onEvent: @escaping (AgentStreamEvent) -> Void
    ) where T.Element == Message {
        let initialMessages = history + [AgentPrompt.completeTask(task: input, relevantDocuments: relevantDocuments, summary: summary)]
        executeStep(model: model, messages: initialMessages, onEvent: onEvent)
    }

    private func executeStep(
        model: String,
        messages: [Message],
        onEvent: @escaping (AgentStreamEvent) -> Void
    ) {
        
        var action = ""
        var aiResponse = ""
        let parser = TagStreamParser()
        
        self.cancellable = OllamaService.shared.chat(
            model: model,
            messages: messages.compactMap(OllamaService.toChatRequestMessage)
        )
        .sink { completion in
            if case .failure(let error) = completion {
                onEvent(.error(error))
            }
        } receiveValue: { response in
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
                    var toolCallResult = ""
                    do {
                        toolCallResult = try ToolExecutor.shared.dispatch(toolCall)
                    } catch {
                        toolCallResult = "Error: \(error.localizedDescription)"
                        onEvent(.error(error))
                    }
                    print("Tool Call Result: \(toolCallResult)")
                    let observation = "<observation>\(toolCallResult)</observation>"
                    onEvent(.token(observation))
                    let aiMessage = Message(role: .assistant, content: aiResponse)
                    let toolMessage = Message(role: .tool, content: observation)
                    let updatedHistory = messages + [aiMessage, toolMessage]
                    action = ""
                    self.stop()
                    self.executeStep(model: model, messages: updatedHistory, onEvent: onEvent)
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
        cancellable?.cancel()
        cancellable = nil
    }
}
