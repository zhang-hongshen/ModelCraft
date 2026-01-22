//
//  Message.swift
//  ModelCraft
//
//  Created by Hongshen on 22/3/2024.
//
import Foundation
import SwiftData
import SwiftUI

@Model
class Message {
    @Attribute(.unique) var id = UUID()
    
    var createdAt: Date = Date.now
    var chat: Chat?
    var role: MessageRole
    var content: String
    var images: [Data]
    var status: MessageStatus
    
    init(role: MessageRole = .user, chat: Chat? = nil, content: String = "",
         images: [Data] = [], status: MessageStatus = .generated) {
        self.chat = chat
        self.role = role
        self.content = content
        self.images = images
        self.status = status
    }
    
}


enum MessageRole: Codable {
    case user, assistant, system, tool
    
    var localizedName: LocalizedStringKey {
        switch self {
        case .user: "You"
        case .assistant: "Assistant"
        case .system: "System"
        case .tool: "Tool"
        }
    }
    
    var icon: Image {
        switch self {
        case .user:
            Image("User")
        case .assistant:
            Image("Assistant")
        case .system:
            Image("Assistant")
        case .tool:
            Image(systemName: "apple.terminal")
        }
    }
}

enum MessageStatus: Codable {
    case new, generating, failed, generated
}
