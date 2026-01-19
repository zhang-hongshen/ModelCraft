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
    
    private let engine = AgentEngine()
    
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
        let userMessage = Message(role: .user, content: content, images: images)
        let assistantMessage = Message(role: .assistant, status: .new)
        
        try await chatModelActor.addMessages(
            chatID: chat.id,
            messages: [userMessage, assistantMessage])
        
        chat.status = .userWaitingForResponse
        
        var relevantDocuments: [String] = []
        if let knowledgeBase = knowledgeBase {
            relevantDocuments = await knowledgeBase.search(content)
        }
        
        engine.run(
            model: model,
            input: content,
            history: chat.messages.suffix(from: chat.lastSummaryIndex),
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
                
            case .error:
                assistantMessage.status = .failed
                resetChatStatus(chat: chat)
            }
        }
        
        Task(priority: .background) {
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
        try await chatModelActor.deleteMessages(chatID: chat.id, messages: messages)
        try await sendMessage(model: model, knowledgeBase: knowledgeBase, chat: chat, content: message.content, images: message.images)
    }
    
    private func getEndSummaryIndex(chat: Chat) -> Int? {
        let bufferCount = 4
        let threshold = 20
        let unsummarizedCount = chat.messages.count - chat.lastSummaryIndex - bufferCount
        guard unsummarizedCount >= threshold else { return nil }
        let endSummaryIndex = chat.messages.count - bufferCount - 1
        return endSummaryIndex
    }
    
    private func summarizeChatIfNeeded (model: String, chat: Chat) async throws{
        guard let endSummaryIndex = getEndSummaryIndex(chat: chat) else { return }
        let summarySlice = chat.sortedMessages[chat.lastSummaryIndex...endSummaryIndex]
        let prompt = AgentPrompt.summarize(
            previousSummary: chat.summary,
            messages: summarySlice
        )
        let response = try await OllamaService.shared.chat(
            model: model,
            messages: [prompt].compactMap(OllamaService.toChatRequestMessage))
        if let summary = response.message?.content {
            chat.lastSummaryIndex = endSummaryIndex
            chat.summary = summary
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
        Task {
            await chatModelActor.setStatus(chatID: chat.id, status: .assistantWaitingForRequest)
        }
    }
}
