//
//  Chat+WorkBuddy.swift
//  ModelCraft
//
//  Created by Hongshen on 31/10/26.
//

import Foundation
import SwiftData
import MLXLMCommon

extension Chat {

    /// Where WorkBuddy keeps its session transcripts, one folder per working directory.
    static let workBuddySessionsDirectory = URL.homeDirectory.appending(
        path: ".workbuddy/projects",
        directoryHint: .isDirectory)

    /// Imports every WorkBuddy session not imported before, skipping transcripts with no
    /// conversation. Yields between sessions so the UI stays responsive.
    @MainActor
    static func importWorkBuddySessions() async throws {
        let context = ModelContainer.shared.mainContext
        var projects = try context.fetch(Project.fetch())
        let importedIDs = try importedSessionIDs()
        let fileManager = FileManager.default
        // Each working directory's folder holds its sessions at the top level; saved tool
        // results sit in subfolders.
        for folder in try fileManager.contentsOfDirectory(
            at: workBuddySessionsDirectory, includingPropertiesForKeys: nil) {
            let files = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let sessionID = file.deletingPathExtension().lastPathComponent
                guard !importedIDs.contains(sessionID),
                      let chat = try? importWorkBuddySession(at: file, projects: &projects)
                else { continue }
                chat.importedSessionID = sessionID
                await Task.yield()
            }
        }
        try context.save()
    }

    /// Creates a chat from a WorkBuddy session transcript, read in the order it was written.
    /// User turns keep only the `<user_query>` the user typed, not the context WorkBuddy
    /// wraps around it, and turns without one are left out; reasoning is left out; the
    /// session joins the project for its working directory (see `Project.forImportedSession`).
    @MainActor
    private static func importWorkBuddySession(at url: URL, projects: inout [Project]) throws -> Chat {
        var seenIDs: Set<String> = []
        let entries = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap {
            try? JSONDecoder().decode(WorkBuddyEntry.self, from: Data($0.utf8))
        }.filter { entry in
            // A resent turn can write an entry again.
            entry.id.map { seenIDs.insert($0).inserted } ?? true
        }
        guard entries.contains(where: { $0.type == "message" && $0.role == "user" && $0.userQuery != nil }) else {
            throw RuntimeError(String(localized: "The file has no WorkBuddy conversation."))
        }

        let chat = Chat(
            title: entries.last { $0.aiTitle != nil }?.aiTitle,
            project: entries.last { $0.cwd != nil }?.cwd.flatMap {
                Project.forImportedSession(workingDirectory: $0, projects: &projects)
            })
        ModelContainer.shared.mainContext.insert(chat)

        var messages: [Message] = []
        var toolMessages: [String: Message] = [:]
        func append(_ message: Message, at entry: WorkBuddyEntry) {
            message.parentID = messages.last?.id
            message.createdAt = entry.timestamp ?? .now
            messages.append(message)
        }

        for entry in entries {
            switch (entry.type, entry.role) {
            case ("message", "user"):
                var files: [URL] = []
                for image in entry.content ?? [] {
                    guard let path = image.image?.blobPath,
                          let data = try? Data(contentsOf: URL(filePath: path))
                    else { continue }
                    let pathExtension = image.image?.mime?.split(separator: "/").last.map(String.init) ?? "png"
                    if let file = chat.saveImportedImage(
                        data, named: "\(entry.id ?? UUID().uuidString)-\(files.count)", pathExtension: pathExtension) {
                        files.append(file)
                    }
                }
                guard let query = entry.userQuery else { continue }
                append(Message(role: .user, content: query, files: files), at: entry)
            case ("message", "assistant"):
                let text = entry.content?.compactMap(\.text).joined(separator: "\n\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty else { continue }
                // Text between tool calls and the final answer stay one message.
                if let last = messages.last, last.role == .assistant {
                    last.content += "\n\n" + text
                } else {
                    append(Message(role: .assistant, content: text), at: entry)
                }
            case ("function_call", _):
                guard let name = entry.name else { continue }
                let arguments = entry.arguments.flatMap {
                    try? JSONDecoder().decode([String: JSONValue].self, from: Data($0.utf8))
                } ?? [:]
                let toolMessage = Message(
                    role: .tool,
                    toolCall: ToolCall(function: .init(name: name, arguments: arguments), id: entry.callID),
                    toolCallResult: .error(String(localized: "The session ended before this tool returned.")),
                    status: .failed)
                append(toolMessage, at: entry)
                if let callID = entry.callID {
                    toolMessages[callID] = toolMessage
                }
            case ("function_call_result", _):
                guard let callID = entry.callID, let toolMessage = toolMessages[callID] else { continue }
                let result = entry.output ?? ""
                toolMessage.content = result
                toolMessage.toolCallResult = CallToolResult(content: [.text(TextContent(text: result))], isError: false)
                toolMessage.status = .generated
            default:
                continue
            }
        }

        chat.messages = messages
        try ModelContainer.shared.mainContext.save()
        return chat
    }
}

/// One line of a WorkBuddy session transcript, with only the fields the import reads.
private struct WorkBuddyEntry: Decodable {
    var id: String?
    var type: String
    var role: String?
    var timestamp: Date?
    var cwd: String?
    var aiTitle: String?
    var content: [Block]?
    var name: String?
    var arguments: String?
    var callID: String?
    var output: String?

    /// A content block: text, or an image saved in WorkBuddy's blob store.
    struct Block: Decodable {
        var text: String?
        var image: Image?

        struct Image: Decodable {
            var mime: String?
            var blobPath: String?

            enum CodingKeys: String, CodingKey {
                case mime
                case blobPath = "blob_path"
            }
        }
    }

    /// The text the user typed, which WorkBuddy wraps in `<user_query>` after the context
    /// it adds to the turn.
    var userQuery: String? {
        let text = content?.compactMap(\.text).joined(separator: "\n") ?? ""
        guard let start = text.range(of: "<user_query>", options: .backwards),
              let end = text.range(of: "</user_query>", range: start.upperBound..<text.endIndex)
        else { return nil }
        let query = text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? nil : query
    }

    enum CodingKeys: String, CodingKey {
        case id, type, role, timestamp, cwd, aiTitle, content, name, arguments, output
        case callID = "callId"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        role = try? container.decodeIfPresent(String.self, forKey: .role)
        // Milliseconds since 1970.
        timestamp = (try? container.decodeIfPresent(Double.self, forKey: .timestamp))
            .map { Date(timeIntervalSince1970: $0 / 1000) }
        cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
        aiTitle = try? container.decodeIfPresent(String.self, forKey: .aiTitle)
        content = try? container.decodeIfPresent([Block].self, forKey: .content)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        arguments = try? container.decodeIfPresent(String.self, forKey: .arguments)
        callID = try? container.decodeIfPresent(String.self, forKey: .callID)
        // A tool result is one text block or a list of them.
        output = (try? container.decodeIfPresent(Block.self, forKey: .output))?.text
            ?? (try? container.decodeIfPresent([Block].self, forKey: .output))?
                .compactMap(\.text).joined(separator: "\n")
    }
}
