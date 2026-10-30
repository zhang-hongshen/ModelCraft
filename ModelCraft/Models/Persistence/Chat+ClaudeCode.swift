//
//  Chat+ClaudeCode.swift
//  ModelCraft
//
//  Created by Hongshen on 30/10/26.
//

import Foundation
import SwiftData
import MLXLMCommon

extension Chat {

    /// Where Claude Code keeps its session transcripts, one folder per working directory.
    static let claudeCodeSessionsDirectory = URL.homeDirectory.appending(
        path: ".claude/projects",
        directoryHint: .isDirectory)

    /// Creates a chat from a Claude Code session transcript, the JSONL file Claude Code
    /// writes with one entry per line. The conversation is read the way Claude Code reads
    /// it: from the latest entry up through each entry's parent, plus the side branches
    /// parallel tool calls leave. Thinking is left out; a session whose working directory
    /// is a project's folder joins that project.
    @MainActor
    static func importClaudeCodeSession(at url: URL, projects: [Project]) throws -> Chat {
        let decoder = JSONDecoder()
        var entries: [ClaudeCodeEntry] = []
        for line in try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline) {
            // Entry kinds this importer does not know are skipped rather than failing it.
            if let entry = try? decoder.decode(ClaudeCodeEntry.self, from: Data(line.utf8)) {
                entries.append(entry)
            }
        }

        let entriesByID = Dictionary(entries.compactMap { entry in entry.uuid.map { ($0, entry) } }) {
            first, _ in first
        }
        var chain: Set<String> = []
        var entry = entries.last { $0.uuid != nil && $0.message != nil && $0.isSidechain != true }
        while let current = entry, let id = current.uuid {
            chain.insert(id)
            // A compaction boundary starts a new chain and names the one it continues.
            entry = (current.parentUuid ?? current.logicalParentUuid).flatMap { entriesByID[$0] }
        }
        // Each tool call of a reply is its own entry, and parallel calls and their results
        // branch off the chain. Every entry of a reply on the chain is kept, with the
        // results of its tool calls, in the order they were written.
        let replyIDs = Set(entries.compactMap { entry in
            entry.uuid.map(chain.contains) == true && entry.message?.role == "assistant"
                ? entry.message?.id : nil
        })
        func isInReply(_ entry: ClaudeCodeEntry) -> Bool {
            entry.uuid.map(chain.contains) == true
                || (entry.message?.role == "assistant" && entry.message?.id.map(replyIDs.contains) == true)
        }
        let toolUseIDs = Set(entries.filter(isInReply).flatMap {
            $0.message?.content.blocks.compactMap(\.id) ?? []
        })
        let path = entries.filter { entry in
            isInReply(entry)
                || entry.message?.content.blocks.contains { $0.toolUseID.map(toolUseIDs.contains) == true } == true
        }
        guard !path.isEmpty else {
            throw RuntimeError(String(localized: "The file has no Claude Code conversation."))
        }

        let chat = Chat(
            title: entries.last { $0.customTitle != nil }?.customTitle,
            project: path.last?.cwd.flatMap { cwd in
                projects.first { $0.workingDirectory?.path == URL(filePath: cwd).standardizedFileURL.path }
            })
        ModelContainer.shared.mainContext.insert(chat)

        var messages: [Message] = []
        var toolMessages: [String: Message] = [:]
        func append(_ message: Message, at entry: ClaudeCodeEntry) {
            message.parentID = messages.last?.id
            message.createdAt = entry.timestamp ?? .now
            messages.append(message)
        }

        for entry in path {
            guard let message = entry.message,
                  entry.isMeta != true, entry.isCompactSummary != true
            else { continue }
            switch message.role {
            case "user":
                var text: [String] = []
                var files: [URL] = []
                for block in message.content.blocks {
                    switch block.type {
                    case "text":
                        text.append(block.text ?? "")
                    case "image":
                        if let file = chat.saveImage(block, named: "\(entry.uuid ?? UUID().uuidString)-\(files.count)") {
                            files.append(file)
                        }
                    case "tool_result":
                        guard let toolUseID = block.toolUseID,
                              let toolMessage = toolMessages[toolUseID] else { continue }
                        let result = block.content?.blocks.compactMap(\.text).joined(separator: "\n") ?? ""
                        toolMessage.content = result
                        toolMessage.toolCallResult = CallToolResult(
                            content: [.text(TextContent(text: result))],
                            isError: block.isError == true)
                        toolMessage.status = block.isError == true ? .failed : .generated
                    default:
                        continue
                    }
                }
                guard !text.isEmpty || !files.isEmpty else { continue }
                append(Message(role: .user, content: text.joined(separator: "\n\n"), files: files), at: entry)
            case "assistant":
                for block in message.content.blocks {
                    switch block.type {
                    case "text":
                        guard let text = block.text, !text.isEmpty else { continue }
                        // One reply arrives as several entries; its text stays one message.
                        if let last = messages.last, last.role == .assistant {
                            last.content += "\n\n" + text
                        } else {
                            append(Message(role: .assistant, content: text), at: entry)
                        }
                    case "tool_use":
                        guard let name = block.name else { continue }
                        let toolMessage = Message(
                            role: .tool,
                            toolCall: ToolCall(
                                function: .init(name: name, arguments: block.input ?? [:]),
                                id: block.id),
                            toolCallResult: .error(String(localized: "The session ended before this tool returned.")),
                            status: .failed)
                        append(toolMessage, at: entry)
                        if let id = block.id {
                            toolMessages[id] = toolMessage
                        }
                    default:
                        continue
                    }
                }
            default:
                continue
            }
        }

        chat.messages = messages
        try ModelContainer.shared.mainContext.save()
        return chat
    }

    /// Writes a base64 image block into the chat's folder.
    private func saveImage(_ block: ClaudeCodeEntry.Block, named name: String) -> URL? {
        guard let source = block.source, source.type == "base64",
              let data = Data(base64Encoded: source.data ?? "")
        else { return nil }
        let pathExtension = source.mediaType?.split(separator: "/").last.map(String.init) ?? "png"
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

/// One line of a Claude Code session transcript, with only the fields the import reads.
private struct ClaudeCodeEntry: Decodable {
    var uuid: String?
    var parentUuid: String?
    var logicalParentUuid: String?
    var isSidechain: Bool?
    var isMeta: Bool?
    var isCompactSummary: Bool?
    var timestamp: Date?
    var cwd: String?
    var customTitle: String?
    var message: EntryMessage?

    struct EntryMessage: Decodable {
        /// The API message ID, which every entry of one reply shares.
        var id: String?
        var role: String
        var content: Content
    }

    /// Message content is either plain text or a list of blocks.
    enum Content: Decodable {
        case text(String)
        case blocks([Block])

        var blocks: [Block] {
            switch self {
            case .text(let text): [Block(type: "text", text: text)]
            case .blocks(let blocks): blocks
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                self = .blocks(try container.decode([Block].self))
            }
        }
    }

    struct Block: Decodable {
        var type: String
        var text: String?
        var id: String?
        var name: String?
        var input: [String: JSONValue]?
        var toolUseID: String?
        var content: Content?
        var isError: Bool?
        var source: Source?

        enum CodingKeys: String, CodingKey {
            case type, text, id, name, input, content, source
            case toolUseID = "tool_use_id"
            case isError = "is_error"
        }
    }

    struct Source: Decodable {
        var type: String
        var mediaType: String?
        var data: String?

        enum CodingKeys: String, CodingKey {
            case type, data
            case mediaType = "media_type"
        }
    }

    enum CodingKeys: String, CodingKey {
        case uuid, parentUuid, logicalParentUuid, isSidechain, isMeta, isCompactSummary
        case timestamp, cwd, customTitle, message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
        parentUuid = try container.decodeIfPresent(String.self, forKey: .parentUuid)
        logicalParentUuid = try container.decodeIfPresent(String.self, forKey: .logicalParentUuid)
        isSidechain = try container.decodeIfPresent(Bool.self, forKey: .isSidechain)
        isMeta = try container.decodeIfPresent(Bool.self, forKey: .isMeta)
        isCompactSummary = try container.decodeIfPresent(Bool.self, forKey: .isCompactSummary)
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
            .flatMap { try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) }
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        // Entries such as attachments have no message, and some carry one this importer
        // cannot read; either way they still link the chain.
        message = try? container.decodeIfPresent(EntryMessage.self, forKey: .message)
    }
}
