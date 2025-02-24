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
            Image("User")
        case .assistant:
            Image("Assistant")
        case .system:
            Image("Assistant")
        }
    }
}

enum MessageStatus: Codable {
    case new, generating, failed, generated
}

@Model
class Message {
    @Attribute(.unique) let id = UUID()
    
    let createdAt: Date = Date.now
    var role: MessageRole
    var content: String
    var images: [Data]
    var status: MessageStatus
    var chat: Chat?
    var conversation: Conversation?
    
    var evalCount: Int? = nil
    var evalDuration: Int? = nil
    var loadDuration: Int? = nil
    var promptEvalCount: Int? = nil
    var promptEvalDuration: Int? = nil
    var totalDuration: Int? = nil
    
    init(role: MessageRole = .user, content: String = "", 
         images: [Data] = [], status: MessageStatus = .generated) {
        self.role = role
        self.content = content
        self.images = images
        self.status = status
    }
    
    var evalDurationInSecond: Double? {
        guard let evalDuration else { return nil }
        
        return Double(evalDuration) / 1_000_000_000
    }
    
    var tokenPerSecond: Double? {
        guard let evalCount, let evalDurationInSecond, evalDurationInSecond > 0 else { return nil }
        return Double(evalCount) / evalDurationInSecond
    }
}
