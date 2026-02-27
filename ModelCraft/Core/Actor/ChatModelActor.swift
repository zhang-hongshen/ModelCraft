//
//  ChatModelActor.swift
//  ModelCraft
//
//  Created by Hongshen on 11/1/26.
//

import SwiftData
import Foundation

@ModelActor
actor ChatModelActor {
    
    func create() throws -> Chat  {
        let chat = Chat()
        modelContext.persist(chat)
        return chat
    }
    
    func prepareMessagesForTask(chatID: PersistentIdentifier, messages: [Message]) throws -> ([Message], String?) {
        guard let chat = modelContext.model(for: chatID) as? Chat else {
            throw NSError(domain: "Chat Not Found", code: 404)
        }
        
        let history = Array(chat.sortedMessages.suffix(from: chat.lastSummaryIndex))
        
        for message in messages {
            if let msg = modelContext.model(for: message.id) as? Message {
                msg.chat = chat
            }
        }
        
        return (history, chat.summary)
    }
    
    func addMessages(chatID: PersistentIdentifier, messages: [Message]) throws -> Void {
        guard let chat = modelContext.model(for: chatID) as? Chat else { return }
        for message in messages {
            message.chat = chat
        }
        
        modelContext.persist(messages)
    }
    
    func deleteMessages(chatID: PersistentIdentifier, after message: Message) throws -> Void {
        guard let chat = modelContext.model(for: chatID) as? Chat else { return }
        guard let index = chat.sortedMessages.firstIndex (where: { $0.id == message.id }) else { return }
        let messagesToDelete = Array(chat.sortedMessages[index...])
        chat.truncateMessages(messages: messagesToDelete)
        modelContext.delete(messagesToDelete)
        try modelContext.save()
    }
    
    func updateSummary(chatID: PersistentIdentifier, summaryLogic: (String?, [Message]) async throws -> String?) async throws {
            guard let chat = modelContext.model(for: chatID) as? Chat else { return }
            
            let sorted = chat.messages.sorted { $0.createdAt < $1.createdAt }
            
            let bufferCount = 4
            let threshold = 20
            let unsummarizedCount = sorted.count - chat.lastSummaryIndex - bufferCount
            
            guard unsummarizedCount >= threshold else { return }

            let endSummaryIndex = sorted.count - bufferCount - 1
            let summarySlice = Array(sorted[chat.lastSummaryIndex + 1...endSummaryIndex])
            
            guard let newSummary = try await summaryLogic(chat.summary, summarySlice) else {
                return
            }
            chat.lastSummaryIndex = endSummaryIndex
            chat.summary = newSummary
            
            try modelContext.save()
        }
    
    
    func generateTitle(chatID: PersistentIdentifier, summaryLogic: ([Message]) async throws -> String?) async throws {
            guard let chat = modelContext.model(for: chatID) as? Chat else { return }
            if chat.title != nil {
                return
            }
            guard let newTitle = try await summaryLogic(chat.sortedMessages) else { return }
            chat.title = newTitle
            try modelContext.save()
        }
    
}
