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
        
        var currentActionBuffer = ""
        var aiResponse = ""
        
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
            let parser = TagStreamParser()
            for event in parser.feed(aiResponse) {
                switch event {
                case .state(let state):
                    if state != .outside || currentActionBuffer.isEmpty {
                        continue
                    }
                    guard let toolCall = ToolCall(json: currentActionBuffer) else {
                        continue
                    }
                    var toolCallResult = ""
                    do {
                        toolCallResult = try ToolExecutor.shared.dispatch(toolCall)
                    } catch {
                        debugPrint("Tool Call Error \(error.localizedDescription)")
                        continue
                    }
                    let aiMessage = Message(role: .assistant, content: aiResponse)
                    let observation = Message(role: .tool, content: "<observation>\(toolCallResult)</observation>")
                    let updatedHistory = messages + [aiMessage, observation]
                    currentActionBuffer = ""
                    self.stop()
                    self.executeStep(model: model, messages: updatedHistory, onEvent: onEvent)
                case .tag(let name, let content):
                        switch name {
                        case "thought": break
                        case "action": currentActionBuffer += content
                        case "answer": break
                        default:
                            break;
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
