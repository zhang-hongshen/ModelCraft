//
//  Message.swift
//  ModelCraft
//
//  Created by Hongshen on 22/3/24.
//

import Foundation
import CryptoKit
import SwiftData
import SwiftUI
import MLXLMCommon

@Model
class Message {
    @Attribute(.unique) var id = UUID()
    
    var createdAt: Date = Date.now
    /// The message this one follows. A thread's conversation is read by walking these links
    /// up from its leaf, so the order of `Thread.messages` never matters.
    var parentID: UUID?
    var thread: Thread?
    var tickets: [Ticket] = []
    var role: MessageRole
    var content: String
    var files: [URL]
    
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
    
    init(role: MessageRole = .user, thread: Thread? = nil, content: String = "",
         files: [URL] = [], toolCall: ToolCall? = nil, toolCallResult: CallToolResult? = nil,
         status: MessageStatus = .generated) {
        // Read before joining the thread, while this message is not yet its leaf.
        self.parentID = thread?.leafMessage?.id
        self.thread = thread
        self.role = role
        self.content = content
        self.files = files
        self.status = status
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

    var videoGenerationProgress: LTXVideoProgress? {
        guard toolCall?.function.name == ToolNames.textToVideo,
              toolCallResult == nil
        else { return nil }
        return LTXVideoProgress(storedValue: content)
    }

    var imageGenerationProgress: StableDiffusionProgress? {
        guard toolCall?.function.name == ToolNames.textToImage,
              toolCallResult == nil
        else { return nil }
        return StableDiffusionProgress(storedValue: content)
    }
}

extension Message {

    var isWaitingForModelResponse: Bool {
        guard case .assistant = role else { return false }
        return status == .new
    }
    
    /// Holds attachments of drafts that have no thread yet. Drafts are not persisted, so
    /// anything left here at launch is abandoned.
    static let draftDirectory = URL.appSupportDirectory.appending(
        path: "Drafts",
        directoryHint: .isDirectory)

    /// Attachments share immutable content; removing a reference never removes the file.
    func addFiles<T>(_ urls: T) where T: Swift.Collection, T.Element == URL {
        for url in urls {
            do {
                let stored = try ResourceStore.importFile(url)
                if !files.contains(stored) { files.append(stored) }
            } catch {
                print("Importing file failed \(url.lastPathComponent): \(error)")
            }
        }
    }

    func removeFiles<T>(_ urls: T) where T: Swift.Collection, T.Element == URL {
        let removed = Set(urls)
        files.removeAll { removed.contains($0) }
    }

    /// Includes textual links as well as structured tool output so copied links stay valid.
    var resourceReferences: String {
        content + files.map(\.absoluteString).joined(separator: "\n") + (_toolCallResult ?? "") + (_toolCall ?? "")
    }

}

/// Lifecycle of a tool call in the thread UI (labels, progress).
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

/// Immutable, content-addressed resources shared by messages and media tools.
/// Collection runs only at launch, before drafts and generation can hold unsaved references.
enum ResourceStore {
#if DEBUG
    static let directory = URL.appSupportDirectory.appending(path: "Resources-Debug", directoryHint: .isDirectory)
#else
    static let directory = URL.appSupportDirectory.appending(path: "Resources", directoryHint: .isDirectory)
#endif
    private static let lock = NSLock()

    static func importFile(_ source: URL) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        let key = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let folder = directory.appending(path: key, directoryHint: .isDirectory)
        let manager = FileManager.default
        if manager.fileExists(atPath: folder.path),
           let existing = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first {
            return existing
        }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        do {
            try manager.copyItem(at: source, to: destination)
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
        return destination
    }

    @MainActor
    static func collectUnreferenced() throws {
        let context = ModelContainer.shared.mainContext
        let messages = try context.fetch(FetchDescriptor<Message>())
        let references = messages.map(\.resourceReferences).joined(separator: "\n")
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return }
        for folder in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if !references.contains(folder.lastPathComponent) {
                try manager.removeItem(at: folder)
            }
        }
    }
}
