//
//  Chat.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 22/3/2024.
//
import Foundation
import SwiftData
 
@Model
class Chat {
    @Attribute(.unique) var id = UUID()
    var createdAt: Date =  Date.now

    @Relationship(deleteRule: .cascade, inverse: \Conversation.chat)
    var conversations: [Conversation]

    init(conversations: [Conversation] = []) {
        self.conversations = conversations
    }
    
}

extension Chat {
    @Transient var title: String {
        guard let message = orderedConversations.first?.userMessages.first else {
            return "New Chat"
        }
        return String(message.content.prefix(20))
    }
    
    @Transient var orderedConversations: [Conversation] {
        conversations.sorted(using: KeyPathComparator(\.createdAt, order: .forward))
    }
}
