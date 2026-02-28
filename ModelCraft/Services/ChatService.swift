//
//  ChatService.swift
//  ModelCraft
//
//  Created by Hongshen on 11/1/26.
//

import SwiftUI
import SwiftData

@Observable
class ChatService {
    
    private let chatModelActor = ChatModelActor(modelContainer: ModelContainer.shared)
    
    private let executor = AgentExecutor()
    
    private var currentTask: Task<Void, any Error>? = nil
    
    @MainActor
    func createChat() -> Chat {
        let chat = Chat()
        ModelContainer.shared.mainContext.persist(chat)
        return chat
    }
    
    @MainActor
    func sendMessage(
        model: LMModel,
        knowledgeBase: KnowledgeBase?,
        chat: Chat,
        message: Message,
    ) async throws {
        
        ModelContainer.shared.mainContext.persist(message)
        
        currentTask = Task {
            try await executor.run(model: model, knowledgeBaseID: knowledgeBase?.persistentModelID, chat: chat, message: message)
        }
        
        Task(priority: .background) {
            try await generateTitleIfNeeded(model: model, chatID: chat.id)
            try await summarizeChatIfNeeded(model: model, chatID: chat.id)
        }
        try await withTaskCancellationHandler {
            try await currentTask?.value
        } onCancel: {
            Task { @MainActor in
                currentTask?.cancel()
            }
        }
        currentTask = nil
    }
    
    @MainActor
    func resendMessage(
        model: LMModel,
        knowledgeBase: KnowledgeBase?,
        chat: Chat,
        message: Message
    ) async throws {
        guard let index = chat.sortedMessages.firstIndex (where: { $0.id == message.id }) else { return }
        let messagesToDelete = Array(chat.sortedMessages[(index+1)...])
        chat.truncateMessages(messages: messagesToDelete)
        ModelContainer.shared.mainContext.delete(messagesToDelete)
        try await sendMessage(
            model: model,
            knowledgeBase: knowledgeBase,
            chat: chat,
            message: message)
    }
    
    private func summarizeChatIfNeeded (model: LMModel, chatID: PersistentIdentifier) async throws {
        try await chatModelActor.updateSummary(chatID: chatID) { previousSummary, messages in
                let prompt = AgentPrompt.summarize(previousSummary: previousSummary, messages: messages)
            return try await MLXService.shared.generate(
                model: model,
                messages: [prompt])
        }
    }

    private func generateTitleIfNeeded (model: LMModel, chatID: PersistentIdentifier) async throws {
        try await chatModelActor.generateTitle(chatID: chatID) { messages in
            let prompt = AgentPrompt.generateTitle(messages: messages)
            return try await MLXService.shared.generate(
                model: model,
                messages: [prompt])
        }
    }
    
    func stopGenerating(chat: Chat) {
        currentTask?.cancel()
        currentTask = nil
        if let currentMessage = chat.currentGeneratingAssistantMessage {
            currentMessage.status = .generated
        }
    }
}
