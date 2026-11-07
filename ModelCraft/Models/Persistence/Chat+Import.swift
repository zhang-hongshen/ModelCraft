//
//  Chat+Import.swift
//  ModelCraft
//
//  Created by Hongshen on 31/10/26.
//

import Foundation
import SwiftData

/// An agent app whose sessions can be imported as chats.
enum SessionSource: String, CaseIterable, Identifiable {
    case claudeCode
    case codex
    case workBuddy

    var id: Self { self }

    /// The app's name, which is not translated.
    var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .workBuddy: "WorkBuddy"
        }
    }

    /// The app's icon in the asset catalog.
    var imageName: String {
        switch self {
        case .claudeCode: "Agents/ClaudeCode"
        case .codex: "Agents/Codex"
        case .workBuddy: "Agents/WorkBuddy"
        }
    }

    /// Imports every session of this app not imported before.
    @MainActor
    func importSessions() async throws {
        switch self {
        case .claudeCode: try await Chat.importClaudeCodeSessions()
        case .codex: try await Chat.importCodexSessions()
        case .workBuddy: try await Chat.importWorkBuddySessions()
        }
    }
}

extension Chat {

    /// The IDs of the sessions chats were imported from.
    @MainActor
    static func importedSessionIDs() throws -> Set<String> {
        Set(try ModelContainer.shared.mainContext.fetch(FetchDescriptor<Chat>(
            predicate: #Predicate { $0.importedSessionID != nil })).compactMap(\.importedSessionID))
    }

    /// Writes an image from an imported session into the chat's folder.
    func saveImportedImage(_ data: Data, named name: String, pathExtension: String) -> URL? {
        let file = directory.appending(path: "\(name).\(pathExtension)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file)
            return file
        } catch {
            return nil
        }
    }
}
