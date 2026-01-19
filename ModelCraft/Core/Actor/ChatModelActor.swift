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
    
    func setStatus(chatID: PersistentIdentifier, status: ChatStatus) {
        guard let chat = modelContext.model(for: chatID) as? Chat else { return }
        chat.status = status
    }
    
    func deleteMessages(chatID: PersistentIdentifier, messages: [Message]) throws -> Void {
        guard let chat = modelContext.model(for: chatID) as? Chat else { return }
        modelContext.delete(messages)
        try modelContext.save()
    }
    
}
