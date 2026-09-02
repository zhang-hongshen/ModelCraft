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
    var files: [URL]
    var prefillTime: TimeInterval?
    var tokensPerSecond: Double?
    
    private var _toolCall: String?
    private var _toolCallResult: String?
    
    @Transient var toolCallResult: CallToolResult? {
        get {
            guard let data = _toolCallResult?.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(CallToolResult.self, from: data)
        }
        
        set {
            guard let newValue else {
                _toolCallResult = nil
                return
            }
            
            if let data = try? JSONEncoder().encode(newValue) {
                _toolCallResult = String(data: data, encoding: .utf8)
            } else {
                _toolCallResult = nil
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
         files: [URL] = [], toolCall: ToolCall? = nil, toolCallResult: CallToolResult? = nil,
         status: MessageStatus = .generated, prefillTime: TimeInterval? = nil,
         tokensPerSecond: Double? = nil) {
        self.chat = chat
        self.role = role
        self.content = content
        self.files = files
        self.status = status
        self.prefillTime = prefillTime
        self.tokensPerSecond = tokensPerSecond
        self.toolCall = toolCall
        self.toolCallResult = toolCallResult
    }
        
    /// UI state for the tool row when this message carries a `toolCall`; `nil` if there is no tool call.
    var toolCallStatus: ToolCallStatus {
        guard let result = toolCallResult else {
            return .running
        }
        return result.isError ? .failed : .completed
    }
}

extension Message {

    var isWaitingForFirstToken: Bool {
        guard case .assistant = role else { return false }
        return status == .generating && content.isEmpty
    }
    
    func addFiles<T>(_ urls: T) where T: Swift.Collection, T.Element == URL {
        var addedFiles: [URL] = []
        let fileManager = FileManager.default
        for url in urls {
            let destinationURL = URL.documentsDirectory.appendingPathComponent(url.lastPathComponent)
            
            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: url, to: destinationURL)
                addedFiles.append(destinationURL)
            } catch {
                print("Moving File failed \(url.lastPathComponent): \(error)")
            }
        }
        files.append(contentsOf: addedFiles)
    }
    
    func removeFiles<T>(_ urls: T) where T: Swift.Collection, T.Element == URL {
        var removedFiles: [URL] = []
        let fileManager = FileManager.default
        for url in urls {
            if fileManager.fileExists(atPath: url.path) {
                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    print("Removing File failed \(url.lastPathComponent): \(error)")
                }
                removedFiles.append(url)
            }
        }
        files.removeAll { removedFiles.contains($0) }
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
    case generating, failed, generated
}
