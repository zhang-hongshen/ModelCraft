//
//  Chat+Codex.swift
//  ModelCraft
//
//  Created by Hongshen on 31/10/26.
//

import Foundation
import SwiftData
import MLXLMCommon

extension Chat {

    /// Where Codex keeps its session rollouts, in one folder per day.
    static let codexSessionsDirectory = URL.homeDirectory.appending(
        path: ".codex/sessions",
        directoryHint: .isDirectory)

    /// Codex's list of session names, one JSON entry per line; a later entry renames.
    private static let codexSessionIndex = URL.homeDirectory.appending(path: ".codex/session_index.jsonl")

    /// Imports every Codex session not imported before, skipping subagent sessions and
    /// rollouts with no conversation. Compressed (`.jsonl.zst`) rollouts are not read.
    /// Yields between sessions so the UI stays responsive.
    @MainActor
    static func importCodexSessions() async throws {
        let context = ModelContainer.shared.mainContext
        var projects = try context.fetch(Project.fetch())
        let importedIDs = try importedSessionIDs()
        var titles: [String: String] = [:]
        if let index = try? String(contentsOf: codexSessionIndex, encoding: .utf8) {
            for line in index.split(whereSeparator: \.isNewline) {
                if let entry = try? JSONDecoder().decode(CodexIndexEntry.self, from: Data(line.utf8)) {
                    titles[entry.id] = entry.threadName
                }
            }
        }
        guard let files = FileManager.default.enumerator(
            at: codexSessionsDirectory, includingPropertiesForKeys: nil)
        else { return }
        for case let file as URL in files where file.pathExtension == "jsonl" {
            // rollout-<date>T<time>-<session ID>.jsonl
            let sessionID = String(file.deletingPathExtension().lastPathComponent.suffix(36))
            guard !importedIDs.contains(sessionID),
                  let chat = try? importCodexSession(at: file, title: titles[sessionID], projects: &projects)
            else { continue }
            chat.importedSessionID = sessionID
            await Task.yield()
        }
        try context.save()
    }

    /// Creates a chat from a Codex session rollout. User turns come from the input the user
    /// typed, not from the context Codex adds around it; reasoning is left out; the session
    /// joins the project for its working directory (see `Project.forImportedSession`).
    @MainActor
    private static func importCodexSession(at url: URL, title: String?, projects: inout [Project]) throws -> Chat {
        let lines = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap {
            try? JSONDecoder().decode(CodexLine.self, from: Data($0.utf8))
        }
        let meta = lines.first { $0.type == "session_meta" }?.payload
        guard meta?.parentThreadID == nil else {
            throw RuntimeError(String(localized: "The file is a subagent session."))
        }
        guard lines.contains(where: { $0.type == "event_msg" && $0.payload?.type == "user_message" }) else {
            throw RuntimeError(String(localized: "The file has no Codex conversation."))
        }

        let chat = Chat(
            title: title,
            project: meta?.cwd.flatMap { Project.forImportedSession(workingDirectory: $0, projects: &projects) })
        ModelContainer.shared.mainContext.insert(chat)

        var messages: [Message] = []
        var toolMessages: [String: Message] = [:]
        func append(_ message: Message, at line: CodexLine) {
            message.parentID = messages.last?.id
            message.createdAt = line.timestamp ?? .now
            messages.append(message)
        }
        func appendToolCall(name: String, arguments: [String: JSONValue], callID: String?, at line: CodexLine) {
            let toolMessage = Message(
                role: .tool,
                toolCall: ToolCall(function: .init(name: name, arguments: arguments), id: callID),
                toolCallResult: .error(String(localized: "The session ended before this tool returned.")),
                status: .failed)
            append(toolMessage, at: line)
            if let callID {
                toolMessages[callID] = toolMessage
            }
        }

        for line in lines {
            guard let payload = line.payload, let type = payload.type else { continue }
            switch (line.type, type) {
            case ("event_msg", "user_message"):
                var files: [URL] = []
                for image in payload.images ?? [] {
                    // data:image/png;base64,<data>
                    guard let comma = image.firstIndex(of: ","),
                          let data = Data(base64Encoded: String(image[image.index(after: comma)...]))
                    else { continue }
                    let pathExtension = image.prefix(upTo: comma).split(separator: "/").last?
                        .split(separator: ";").first.map(String.init) ?? "png"
                    if let file = chat.saveImportedImage(
                        data, named: "\(UUID().uuidString)-\(files.count)", pathExtension: pathExtension) {
                        files.append(file)
                    }
                }
                append(Message(role: .user, content: payload.message ?? "", files: files), at: line)
            case ("response_item", "message") where payload.role == "assistant":
                let text = payload.content?.compactMap(\.text).joined(separator: "\n\n") ?? ""
                guard !text.isEmpty else { continue }
                // Commentary between tool calls and the final answer stay one message.
                if let last = messages.last, last.role == .assistant {
                    last.content += "\n\n" + text
                } else {
                    append(Message(role: .assistant, content: text), at: line)
                }
            case ("response_item", "function_call"):
                guard let name = payload.name else { continue }
                let arguments = payload.arguments.flatMap {
                    try? JSONDecoder().decode([String: JSONValue].self, from: Data($0.utf8))
                } ?? [:]
                appendToolCall(name: name, arguments: arguments, callID: payload.callID, at: line)
            case ("response_item", "custom_tool_call"):
                guard let name = payload.name else { continue }
                appendToolCall(
                    name: name, arguments: ["input": .string(payload.input ?? "")], callID: payload.callID, at: line)
            case ("response_item", "local_shell_call"):
                appendToolCall(name: "shell", arguments: payload.action ?? [:], callID: payload.callID, at: line)
            case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"):
                guard let callID = payload.callID, let toolMessage = toolMessages[callID] else { continue }
                let result = payload.output ?? ""
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

private struct CodexIndexEntry: Decodable {
    var id: String
    var threadName: String

    enum CodingKeys: String, CodingKey {
        case id
        case threadName = "thread_name"
    }
}

/// One line of a Codex rollout, with only the fields the import reads.
private struct CodexLine: Decodable {
    var timestamp: Date?
    var type: String
    var payload: Payload?

    /// The fields of the payload kinds the import reads; each is absent from the others.
    struct Payload: Decodable {
        var type: String?
        // session_meta
        var cwd: String?
        var parentThreadID: String?
        // user_message event
        var message: String?
        var images: [String]?
        // message
        var role: String?
        var content: [ContentItem]?
        // tool calls and their outputs
        var name: String?
        var arguments: String?
        var input: String?
        var action: [String: JSONValue]?
        var callID: String?
        var output: String?

        struct ContentItem: Decodable {
            var text: String?
        }

        enum CodingKeys: String, CodingKey {
            case type, cwd, message, images, role, content, name, arguments, input, action, output
            case parentThreadID = "parent_thread_id"
            case callID = "call_id"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // The same key holds different shapes across payload kinds, so a field that does
            // not fit is left out rather than failing the line.
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
            parentThreadID = try? container.decodeIfPresent(String.self, forKey: .parentThreadID)
            message = try? container.decodeIfPresent(String.self, forKey: .message)
            images = try? container.decodeIfPresent([String].self, forKey: .images)
            role = try? container.decodeIfPresent(String.self, forKey: .role)
            content = try? container.decodeIfPresent([ContentItem].self, forKey: .content)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            arguments = try? container.decodeIfPresent(String.self, forKey: .arguments)
            input = try? container.decodeIfPresent(String.self, forKey: .input)
            action = try? container.decodeIfPresent([String: JSONValue].self, forKey: .action)
            callID = try? container.decodeIfPresent(String.self, forKey: .callID)
            // Tool output is plain text or a list of content items.
            output = (try? container.decodeIfPresent(String.self, forKey: .output))
                ?? (try? container.decodeIfPresent([ContentItem].self, forKey: .output))?
                    .compactMap(\.text).joined(separator: "\n")
        }
    }

    enum CodingKeys: String, CodingKey {
        case timestamp, type, payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
            .flatMap { try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) }
        payload = try? container.decodeIfPresent(Payload.self, forKey: .payload)
    }
}
