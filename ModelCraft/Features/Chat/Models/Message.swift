//
//  Message.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 22/3/2024.
//
import Foundation
import SwiftData
import SwiftUI

enum MessageRole: String {
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
class Message: Codable {
    @Attribute(.unique) let id = UUID()
    private var roleString: String
    
    var createdAt: Date = Date.now
    
    @Transient var role: MessageRole {
        get { MessageRole(rawValue: roleString) ?? .user }
        set { self.roleString = newValue.rawValue }
    }
    var content: String
    var images: [Data]
    
    var chat: Chat?
    
    init(role: MessageRole = .user, content: String = "", images: [Data] = []) {
        self.roleString = role.rawValue
        self.content = content
        self.images = images
    }
    
    private enum CodingKeys: String, CodingKey {
        case content, role, images
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.roleString = try container.decode(String.self, forKey: .role)
        self.content = try container.decode(String.self, forKey: .content)
        self.images = try container.decodeIfPresent([Data].self, forKey: .images) ?? []
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(content, forKey: .content)
        try container.encode(roleString, forKey: .role)
        try container.encode(images, forKey: .images)
    }
}
