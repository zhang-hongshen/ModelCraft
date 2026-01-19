//
//  AgentEngine.swift
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

class AgentEngine {
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
        let parser = TagStreamParser()
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
            aiResponse += token
            
            for event in parser.feed(token) {
                switch event {
                case .state(let state):
                    if state != .outside || currentActionBuffer.isEmpty {
                        continue
                    }
                    let result: String = {
                        do {
                            return try ToolExecutor.shared.dispatch(json: currentActionBuffer)
                        } catch {
                            return "Tool Call Error: \(error.localizedDescription)"
                        }
                    }()
                    
                    let aiMessage = Message(role: .assistant, content: aiResponse)
                    let observation = Message(role: .user, content: "<observation>\(result)</observation>")
                    let updatedHistory = messages + [aiMessage, observation]
                    currentActionBuffer = ""
                    self.stop()
                    self.executeStep(model: model, messages: updatedHistory, onEvent: onEvent)
                case .action(let action):
                    currentActionBuffer += action
                case .think(let think):
                    onEvent(.token(think))
                case .answer(let answer):
                    onEvent(.token(answer))
                }
            }
            
            if response.done && currentActionBuffer.isEmpty {
                onEvent(.finished(aiResponse))
            }
        }
    }
    
    func stop() {
        cancellable?.cancel()
        cancellable = nil
    }
}
