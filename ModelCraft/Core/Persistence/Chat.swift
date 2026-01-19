//
//  Chat.swift
//  ModelCraft
//
//  Created by Hongshen on 22/3/2024.
//

import Foundation
import SwiftData
 
@Model
class Chat {
    
    @Attribute(.unique) var id = UUID()
    
    var title: String?
    
    var createdAt: Date =  Date.now
    
    var summary: String? = nil
    
    var lastSummaryIndex: Int = 0
    
    var status: ChatStatus = ChatStatus.assistantWaitingForRequest
    
    @Relationship(deleteRule: .cascade, inverse: \Message.chat)
    var messages: [Message] = []
    
    init() {}
    
}

extension Chat {
    
    var sortedMessages: [Message] {
        messages.sorted{ $0.createdAt < $1.createdAt }
    }
    
    var currentGeneratingAssistantMessage: Message? {
        sortedMessages.last { $0.role == .assistant && $0.status == .generating }
    }
    
    func truncateMessages(after message: Message) -> [Message] {
        guard let index = sortedMessages.firstIndex (where: { $0.id == message.id }) else { return [] }
        let messagesToDelete = Array(sortedMessages[index...])
        let idsToDelete = Set(messagesToDelete.map { $0.id })
        messages.removeAll { idsToDelete.contains($0.id) }
        return messagesToDelete
    }
    
}

// Possible values of the `chatStatus` property.

enum ChatStatus: Codable {
    case assistantWaitingForRequest
    case userWaitingForResponse
    case assistantResponding
}
