//
//  Message.swift
//  ModelCraft
//
//  Created by Hongshen on 22/3/2024.
//

import Foundation
import SwiftData
import SwiftUI
import MLXLMCommon

@Model
class Message {
    @Attribute(.unique) var id = UUID()
    
    var createdAt: Date = Date.now
    var chat: Chat?
    var role: MessageRole
    var content: String
    var attachments: [URL]
    private var _toolCall: String?
    private var _toolCallResult: String?
    
    @Transient var toolCallResult: CallToolResult? {
        get {
            guard let data = _toolCallResult?.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(CallToolResult.self, from: data)
        }
        
        set {
            guard let newValue else {
                _toolCall = nil
                return
            }
            
            if let data = try? JSONEncoder().encode(newValue) {
                _toolCall = String(data: data, encoding: .utf8)
            } else {
                _toolCall = nil
            }
        }
    }
    
    @Transient var toolCall: ToolCall? {
        get {
            guard let data = _toolCall?.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ToolCall.self, from: data)
        }
        
        set {
            guard let newValue else {
                _toolCall = nil
                return
            }
            
            if let data = try? JSONEncoder().encode(newValue) {
                _toolCall = String(data: data, encoding: .utf8)
            } else {
                _toolCall = nil
            }
        }
    }
    var status: MessageStatus
    
    init(role: MessageRole = .user, chat: Chat? = nil, content: String = "",
         attachments: [URL] = [], toolCall: ToolCall? = nil, toolCallResult: CallToolResult? = nil,
         status: MessageStatus = .generated) {
        self.chat = chat
        self.role = role
        self.content = content
        self.attachments = attachments
        self.status = status
        self.toolCall = toolCall
        self.toolCallResult = toolCallResult
    }
        
    /// UI state for the tool row when this message carries a `toolCall`; `nil` if there is no tool call.
    var toolCallStatus: ToolCallStatus {
        switch toolCallResult {
        case nil:
            return .running
        case let result? where result.isError:
            return .failed
        case .some:
            return .completed
        }
    }
}

/// Lifecycle of a tool call in the chat UI (labels, progress).
enum ToolCallStatus: Codable {
    case running
    case completed
    case failed
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

}

enum MessageStatus: Codable {
    case new, generating, failed, generated
}

