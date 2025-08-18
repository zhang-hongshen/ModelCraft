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
    private var conversationsPersistent = [Conversation]()
    
    @Relationship(deleteRule: .cascade, inverse: \RollingSummary.chat)
    private var rollingSummary: RollingSummary?

    @Transient var conversations: [Conversation] {
        get {
            conversationsPersistent.sorted(using: KeyPathComparator(\.createdAt, order: .forward))
        }
        set {
            conversationsPersistent = newValue
        }
    }
    
    init() {
    }
    
}

extension Chat {
    
    @Transient var title: String {
        guard let message = conversations.first?.userMessage else {
            return "New Chat"
        }
        return String(message.content.prefix(20))
    }
    
    @Transient var allMessages: [Message] {
        self.conversations.flatMap { [$0.userMessage, $0.assistantMessage] }
    }
    
    func allMessages(before: Conversation) -> [Message] {
        guard let index = self.conversations.firstIndex(of: before) else {
            return []
        }
        return self.conversations.prefix(index)
            .flatMap { [$0.userMessage, $0.assistantMessage] }
    }
}

// Possible values of the `chatStatus` property.

enum ChatStatus {
    case assistantWaitingForRequest
    case userWaitingForResponse
    case assistantResponding
}
