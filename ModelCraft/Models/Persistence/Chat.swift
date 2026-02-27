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

    @Relationship(deleteRule: .cascade, inverse: \Message.chat)
    var messages: [Message] = []
    
    init() {}
    
}

extension Chat {
    
    var status: MessageStatus {
        sortedMessages.last?.status ?? .generated
    }
    
    var sortedMessages: [Message] {
        messages.sorted{ $0.createdAt < $1.createdAt }
    }
    
    var currentGeneratingAssistantMessage: Message? {
        sortedMessages.last { $0.role == .assistant && $0.status == .generating }
    }
    
    func truncateMessages(messages: [Message]){
        self.messages.removeAll { messages.map { $0.id }.contains($0.id) }
    }
    
}
