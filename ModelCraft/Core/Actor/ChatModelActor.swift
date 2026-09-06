//
//  ChatModelActor.swift
//  ModelCraft
//
//  Created by Hongshen on 11/1/26.
//

import SwiftData

@ModelActor
actor ChatModelActor {

    func generateTitle(chatID: PersistentIdentifier, summaryLogic: ([Message]) async throws -> String?) async throws {
        guard let chat = modelContext.model(for: chatID) as? Chat else { return }
        if chat.title != nil {
            return
        }
        try Task.checkCancellation()
        guard let newTitle = try await summaryLogic(chat.sortedMessages) else { return }
        try Task.checkCancellation()
        chat.title = newTitle
        try modelContext.save()
    }
    
}
