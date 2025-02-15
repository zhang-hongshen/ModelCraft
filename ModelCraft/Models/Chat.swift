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
    @Attribute(.unique) let id = UUID()
    var createdAt: Date =  Date.now
    
    @Relationship(deleteRule: .cascade, inverse: \Message.chat)
    var messages: [Message]
    
    init(messages: [Message] = []) {
        self.messages = messages
    }
    
}

extension Chat {
    @Transient var title: String {
        guard let message = orderedMessages.first else {
            return "New Chat"
        }
        return String(message.content.prefix(20))
    }
    
    @Transient var orderedMessages: [Message] {
        messages.sorted(using: KeyPathComparator(\.createdAt, order: .forward))
    }
}
