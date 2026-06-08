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

    var project: Project? = nil
    
    @Relationship(deleteRule: .cascade, inverse: \Message.chat)
    var messages: [Message] = []
    
    init(title: String? = nil, project: Project? = nil) {
        self.title = title
        self.project = project
    }
    
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
    
    var isGenerating: Bool {
        sortedMessages.last?.status == .generating
    }
    
    func truncateMessages(messages: [Message]){
        self.messages.removeAll { messages.map { $0.id }.contains($0.id) }
    }
    
    var displayCreatedAt: String {
        if Calendar.current.isDateInToday(createdAt) {
            return createdAt.formatted(date: .omitted, time: .shortened)
        }
        return createdAt.formatted(date: .abbreviated, time: .omitted)
    }
    
}

extension Chat {
    static func fetch(limit: Int? = nil, offset: Int? = nil) -> FetchDescriptor<Chat> {
        var descriptor = FetchDescriptor<Chat>()
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        descriptor.sortBy = [.init(\.createdAt, order: .reverse)]
        return descriptor
    }
}
