//
//  Message.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 22/3/2024.
//
import Foundation
import SwiftData
import SwiftUI

enum MessageRole: Codable {
    case user, assistant, system
    
    var localizedName: LocalizedStringKey {
        switch self {
        case .user: "You"
        case .assistant: "Assistant"
        case .system: "System"
        }
    }
    
    var icon: Image {
        switch self {
        case .user:
            Image(systemName: "person.circle")
        case .assistant:
            Image("Assistant")
        case .system:
            Image("Assistant")
        }
    }
}

@Model
class Message {
    @Attribute(.unique) let id = UUID()
    
    let createdAt: Date = Date.now
    var role: MessageRole
    var content: String
    var images: [Data]
    var done: Bool
    var reference: [LocalFileURL]
    var chat: Chat?
    
    var evalCount: Int? = nil
    var evalDuration: Int? = nil
    var loadDuration: Int? = nil
    var promptEvalCount: Int? = nil
    var promptEvalDuration: Int? = nil
    var totalDuration: Int? = nil
    
    init(role: MessageRole, content: String = "", images: [Data] = [],
         done: Bool = true, reference: [URL] = []) {
        self.role = role
        self.content = content
        self.images = images
        self.done = done
        self.reference = reference
    }
    
}
