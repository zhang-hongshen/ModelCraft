//
//  Conversation.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 2/24/25.
//

import Foundation
import SwiftData

@Model
class Conversation {
    @Attribute(.unique) var id = UUID()
    var createdAt: Date =  Date.now
    
    var chat: Chat?
    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    var userMessages: [Message]
    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    var assistantMessages: [Message]
    
    init(chat: Chat? = nil, userMessages: [Message] = [],
         assistantMessages: [Message] = []) {
        self.userMessages = userMessages
        self.assistantMessages = assistantMessages
    }
}
