//
//  Conversation.swift
//  ModelCraft
//
//  Created by Hongshen on 2/24/25.
//

import Foundation

class Conversation: Identifiable {
    let id = UUID()
    var createdAt: Date =  Date.now
    
    var chat: Chat
    var userMessage: Message
    var assistantMessage: Message
    
    init(chat: Chat, userMessage: Message,
         assistantMessage: Message) {
        self.chat = chat
        self.userMessage = userMessage
        self.assistantMessage = assistantMessage
    }
    
}
