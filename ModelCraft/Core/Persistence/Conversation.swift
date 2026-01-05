//
//  Conversation.swift
//  ModelCraft
//
//  Created by Hongshen on 2/24/25.
//

import Foundation
import SwiftData

@Model
class Conversation {
    @Attribute(.unique) var id = UUID()
    var createdAt: Date =  Date.now
    
    var chat: Chat
    @Relationship(deleteRule: .cascade)
    var userMessage: Message
    
    @Relationship(deleteRule: .cascade)
    var assistantMessage: Message
    
    init(chat: Chat, userMessage: Message,
         assistantMessage: Message) {
        self.chat = chat
        self.userMessage = userMessage
        self.assistantMessage = assistantMessage
    }
    
}
