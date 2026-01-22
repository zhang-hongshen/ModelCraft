//
//  ChatService.swift
//  ModelCraft
//
//  Created by Hongshen on 11/1/26.
//

import SwiftUI
import SwiftData
import Combine

@Observable
class ChatService {
    
    private let container: ModelContainer
    private let chatModelActor: ChatModelActor
    
    private let executor = AgentExecutor()
    
    init(container: ModelContainer) {
        self.container = container
        self.chatModelActor = ChatModelActor(modelContainer: container)
    }
    
    
    func createChat() async throws -> Chat {
        return try await chatModelActor.create()
    }
    
    @MainActor
    func sendMessage(
        model: String,
        knowledgeBase: KnowledgeBase?,
        chat: Chat,
        content: String,
        images: [Data]
    ) async throws {
        let userMessage = Message(role: .user, chat: chat, content: content, images: images)
        let assistantMessage = Message(role: .assistant, chat: chat, status: .new)
        let history = chat.messages.suffix(from: chat.lastSummaryIndex)
        
        try await chatModelActor.addMessages(
            chatID: chat.id,
            messages: [userMessage, assistantMessage])
        chat.status = .userWaitingForResponse
        
        var relevantDocuments: [String] = []
        if let knowledgeBase = knowledgeBase {
            relevantDocuments = await knowledgeBase.search(content)
        }
        
        executor.run(
            model: model,
            input: content,
            history: history,
            relevantDocuments: relevantDocuments,
            summary: chat.summary
        ) { [weak self] event in
            guard let self = self else { return }
            switch event {
            case .token(let text):
                if case .userWaitingForResponse = chat.status {
                    chat.status = .assistantResponding
                    assistantMessage.status = .generating
                }
                guard case .assistantResponding = chat.status else { return }
                assistantMessage.content.append(text)
                
            case .finished:
                assistantMessage.status = .generated
                resetChatStatus(chat: chat)
                
            case .error(let error):
                assistantMessage.content.append(error.localizedDescription)
                assistantMessage.status = .failed
            }
        }
        
        Task(priority: .background) {
            try await generateTitleIfNeeded(model: model, chat: chat)
            try await summarizeChatIfNeeded(model: model, chat: chat)
        }
    }
    
    @MainActor
    func resendMessage(
        model: String,
        knowledgeBase: KnowledgeBase?,
        chat: Chat,
        message: Message
    ) async throws {
        chat.status = .userWaitingForResponse
        let messages = chat.truncateMessages(after: message)
        try await chatModelActor.deleteMessages(messages: messages)
        try await sendMessage(
            model: model,
            knowledgeBase: knowledgeBase,
            chat: chat,
            content: message.content,
            images: message.images)
    }
    
    private func summarizeChatIfNeeded (model: String, chat: Chat) async throws {
        try await chatModelActor.updateSummary(chatID: chat.id, model: model) { previousSummary, messages in
                let prompt = AgentPrompt.summarize(previousSummary: previousSummary, messages: messages)
            let response = try await OllamaService.shared.chat(
                model: model,
                messages: [prompt].compactMap(OllamaService.toChatRequestMessage))
                return response.message?.content
        }
    }

    private func generateTitleIfNeeded (model: String, chat: Chat) async throws {
        if chat.title != nil {
            return
        }
        try await chatModelActor.generateTitle(chatID: chat.id, model: model) { messages in
            let prompt = AgentPrompt.generateTitle(messages: messages)
            let response = try await OllamaService.shared.chat(
                model: model,
                messages: [prompt].compactMap(OllamaService.toChatRequestMessage))
                return response.message?.content
        }
    }
    
    func stopGenerating(chat: Chat?) {
        guard let chat = chat else { return }
        if let currentMessage = chat.currentGeneratingAssistantMessage {
            currentMessage.status = .generated
        }
        resetChatStatus(chat: chat)
    }

    private func resetChatStatus(chat: Chat) {
        chat.status = .assistantWaitingForRequest
        Task {
            try await chatModelActor.updateStatus(chatID: chat.id, status: .assistantWaitingForRequest)
        }
    }
}
