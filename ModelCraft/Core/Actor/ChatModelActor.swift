//
//  ChatModelActor.swift
//  ModelCraft
//
//  Created by Hongshen on 11/1/26.
//

import SwiftData

@ModelActor
actor ChatModelActor {
    
    func create() throws -> Chat  {
        let chat = Chat()
        modelContext.persist(chat)
        return chat
    }
    
    func addMessages(chatID: PersistentIdentifier, messages: [Message]) throws -> Void {
        guard let chat = modelContext.model(for: chatID) as? Chat else { return }
        for message in messages {
            message.chat = chat
        }
        
        modelContext.persist(messages)
    }
    
    func updateStatus(chatID: PersistentIdentifier, status: ChatStatus) throws {
        guard let chat = modelContext.model(for: chatID) as? Chat else { return }
        chat.status = status
        try modelContext.save()
    }
    
    func deleteMessages(messages: [Message]) throws -> Void {
        modelContext.delete(messages)
        try modelContext.save()
    }
    
    func updateSummary(chatID: PersistentIdentifier, model: String, summaryLogic: (String?, [Message]) async throws -> String?) async throws {
            guard let chat = modelContext.model(for: chatID) as? Chat else { return }
            
            let sorted = chat.messages.sorted { $0.createdAt < $1.createdAt }
            
            let bufferCount = 4
            let threshold = 20
            let unsummarizedCount = sorted.count - chat.lastSummaryIndex - bufferCount
            
            guard unsummarizedCount >= threshold else { return }
            
            let endSummaryIndex = sorted.count - bufferCount - 1
            let summarySlice = Array(sorted[chat.lastSummaryIndex...endSummaryIndex])
            
            guard let newSummary = try await summaryLogic(chat.summary, summarySlice) else {
                return
            }
            chat.lastSummaryIndex = endSummaryIndex
            chat.summary = newSummary
            
            try modelContext.save()
        }
    
}
