//
//  Chat.swift
//  ModelCraft
//
//  Created by Hongshen on 22/3/2024.
//

import Foundation
import SwiftData
 
@Model
class Chat {
    
    @Attribute(.unique) var id = UUID()
    
    var title: String?
    
    var createdAt: Date =  Date.now
    
    var summary: String? = nil
    
    var lastSummaryIndex: Int = 0

    var project: Project? = nil
    
    @Relationship(deleteRule: .cascade, inverse: \Message.chat)
    var messages: [Message] = []
    
    init(title: String? = nil, project: Project? = nil) {
        self.title = title
        self.project = project
    }
    
}

extension Chat {
    
    var status: MessageStatus {
        sortedMessages.last?.status ?? .generated
    }
    
    var sortedMessages: [Message] {
        messages.sorted{ $0.createdAt < $1.createdAt }
    }
    
    var currentGeneratingAssistantMessage: Message? {
        sortedMessages.last { $0.role == .assistant && $0.status == .generating }
    }
    
    var isGenerating: Bool {
        sortedMessages.last?.status == .generating
    }
    
    func truncateMessages(messages: [Message]){
        self.messages.removeAll { messages.map { $0.id }.contains($0.id) }
    }
    
    var displayCreatedAt: String {
        if Calendar.current.isDateInToday(createdAt) {
            return createdAt.formatted(date: .omitted, time: .shortened)
        }
        return createdAt.formatted(date: .abbreviated, time: .omitted)
    }
    
}

/// The chat presentation keeps normal messages and contiguous tool work separate.
/// Image generation is intentionally kept as a standalone message so its long-running
/// visual state can occupy the conversation directly.
enum ChatContentItem: Identifiable {
    case message(Message)
    case toolCallGroup([Message])

    var id: String {
        switch self {
        case .message(let message):
            return message.id.uuidString
        case .toolCallGroup(let messages):
            return messages.first?.id.uuidString ?? UUID().uuidString
        }
    }
}

enum ChatContentBuilder {
    static func items(from messages: [Message]) -> [ChatContentItem] {
        var items: [ChatContentItem] = []
        var pendingToolCalls: [Message] = []

        func flushToolCalls() {
            guard !pendingToolCalls.isEmpty else { return }
            if pendingToolCalls.count == 1 {
                items.append(.message(pendingToolCalls[0]))
            } else {
                items.append(.toolCallGroup(pendingToolCalls))
            }
            pendingToolCalls.removeAll(keepingCapacity: true)
        }

        for message in messages {
            guard case .tool = message.role,
                  let toolCall = message.toolCall else {
                flushToolCalls()
                items.append(.message(message))
                continue
            }

            if toolCall.function.name == ToolNames.textToImage {
                flushToolCalls()
                items.append(.message(message))
            } else {
                pendingToolCalls.append(message)
            }
        }

        flushToolCalls()
        return items
    }
}

struct AssistantTurn: Identifiable {
    let userMessage: Message?
    let messages: [Message]

    var id: UUID {
        messages.first?.id ?? userMessage?.id ?? UUID()
    }

    var contentItems: [ChatContentItem] {
        ChatContentBuilder.items(from: messages)
    }

    var content: String {
        messages
            .compactMap { message in
                guard case .assistant = message.role else { return nil }
                return message.content
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    var status: MessageStatus {
        messages.last?.status ?? .generated
    }

    var isWaitingForFirstToken: Bool {
        messages.last?.isWaitingForFirstToken ?? false
    }
}

enum ConversationContentItem: Identifiable {
    case message(Message)
    case assistantTurn(AssistantTurn)

    var id: UUID {
        switch self {
        case .message(let message):
            message.id
        case .assistantTurn(let turn):
            turn.id
        }
    }
}

/// Groups the model's recursive assistant/tool messages into the single reply
/// turn that users perceive after each user message.
enum ConversationContentBuilder {
    static func items(from messages: [Message]) -> [ConversationContentItem] {
        var items: [ConversationContentItem] = []
        var pendingAssistantMessages: [Message] = []
        var latestUserMessage: Message?

        func flushAssistantTurn() {
            guard !pendingAssistantMessages.isEmpty else { return }
            items.append(.assistantTurn(.init(
                userMessage: latestUserMessage,
                messages: pendingAssistantMessages
            )))
            pendingAssistantMessages.removeAll(keepingCapacity: true)
        }

        for message in messages {
            switch message.role {
            case .assistant, .tool:
                pendingAssistantMessages.append(message)
                continue
            default:
                if message.toolCall != nil {
                    pendingAssistantMessages.append(message)
                    continue
                }
            }

            flushAssistantTurn()
            items.append(.message(message))
            if case .user = message.role {
                latestUserMessage = message
            }
        }

        flushAssistantTurn()
        return items
    }
}

struct ToolCallGroupSummary {
    let messages: [Message]

    var isRunning: Bool {
        messages.contains { $0.toolCallStatus == .running }
    }

    var activeToolDescription: String? {
        messages.last(where: { $0.toolCallStatus == .running })?.toolCall?.compactDescription(.running)
    }

    var fileReadCount: Int {
        count(named: ToolNames.readFile)
    }

    var fileWriteCount: Int {
        count(named: ToolNames.writeFile) + count(named: ToolNames.editFile)
    }

    var commandCount: Int {
        count(named: ToolNames.executeCommand)
    }

    var completedDescription: String {
        var descriptions: [String] = []
        if fileWriteCount > 0 {
            descriptions.append(countDescription(
                fileWriteCount,
                singular: "Edited one file",
                plural: "Edited %lld files"
            ))
        }
        if fileReadCount > 0 {
            descriptions.append(countDescription(
                fileReadCount,
                singular: "Read one file",
                plural: "Read %lld files"
            ))
        }
        if commandCount > 0 {
            descriptions.append(countDescription(
                commandCount,
                singular: "Executed one command",
                plural: "Executed %lld commands"
            ))
        }

        guard !descriptions.isEmpty else {
            return String(localized: "Completed")
        }
        return ListFormatter.localizedString(byJoining: descriptions)
    }

    private func count(named name: String) -> Int {
        messages.reduce(into: 0) { count, message in
            if message.toolCall?.function.name == name {
                count += 1
            }
        }
    }

    private func countDescription(_ count: Int, singular: String, plural: String) -> String {
        if count == 1 {
            return String(localized: String.LocalizationValue(singular))
        }
        return String(
            format: String(localized: String.LocalizationValue(plural)),
            Int64(count)
        )
    }
}

extension Chat {
    static func fetch(limit: Int? = nil, offset: Int? = nil) -> FetchDescriptor<Chat> {
        var descriptor = FetchDescriptor<Chat>()
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        descriptor.sortBy = [.init(\.createdAt, order: .reverse)]
        return descriptor
    }
}
