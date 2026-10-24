//
//  Chat.swift
//  ModelCraft
//
//  Created by Hongshen on 22/3/24.
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

    /// The schedule whose run created this chat.
    var schedule: Schedule? = nil
    
    @Relationship(deleteRule: .cascade, inverse: \Message.chat)
    var messages: [Message] = []
    
    var tokenCount: Int = 0
    
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
            // While the model works out its next step, the group stays open and shows
            // that it is still working instead of ending in a separate spinner.
            if message.isWaitingForModelResponse, pendingToolCalls.count > 1 {
                pendingToolCalls.append(message)
                continue
            }

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

    var isWaitingForModelResponse: Bool {
        messages.last?.isWaitingForModelResponse ?? false
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
        guard let message = messages.last(where: { $0.toolCallStatus == .running }) else {
            return nil
        }
        return message.imageGenerationProgress?.localizedDescription
            ?? message.videoGenerationProgress?.localizedDescription
            ?? message.toolCall?.compactDescription(.running)
    }

    var isWaitingForModelResponse: Bool {
        messages.last?.isWaitingForModelResponse ?? false
    }

    /// What the group is doing now while it is live, and what it did once it is done.
    /// Between tool calls the latest step stays in the title until the next one starts.
    var title: String {
        if let activeToolDescription {
            return activeToolDescription
        }
        if isWaitingForModelResponse,
           let message = messages.last(where: { $0.toolCall != nil }),
           let toolCall = message.toolCall {
            return toolCall.compactDescription(message.toolCallStatus)
        }
        return completedDescription
    }

    /// One phrase per kind of work, in the order it first happened. Only one versus
    /// several is told apart; counts are left out.
    var completedDescription: String {
        var activities: [ToolCallActivity] = []
        var occurrences: [ToolCallActivity: Set<String>] = [:]
        for message in messages {
            guard let toolCall = message.toolCall else { continue }
            for (activity, occurrence) in toolCall.activities(id: message.id.uuidString) {
                if occurrences[activity] == nil {
                    activities.append(activity)
                }
                occurrences[activity, default: []].insert(occurrence)
            }
        }

        let descriptions = activities.enumerated().map { index, activity in
            let description = activity.description(isPlural: occurrences[activity, default: []].count > 1)
            // Later phrases continue the sentence that the first one starts.
            return index == 0 ? description : description.prefix(1).lowercased() + description.dropFirst()
        }
        guard !descriptions.isEmpty else {
            return String(localized: "Completed")
        }
        return ListFormatter.localizedString(byJoining: descriptions)
    }
}

/// A kind of work a tool call does, as the summary of a tool call group names it.
enum ToolCallActivity: Hashable {
    case editFile, deleteFile, readFile, listDirectory
    case runCommand, runScript
    case search, fetchWebPage
    case useApp
    case controlComputer, takeScreenshot
    case createImage, createVideo, createAudio
    case loadSkill, askQuestion
    case checkSchedule, changeSchedule

    func description(isPlural: Bool) -> String {
        let resource: LocalizedStringResource = switch (self, isPlural) {
        case (.editFile, false): "Edited a file"
        case (.editFile, true): "Edited files"
        case (.deleteFile, false): "Deleted a file"
        case (.deleteFile, true): "Deleted files"
        case (.readFile, false): "Read a file"
        case (.readFile, true): "Read files"
        case (.listDirectory, false): "Listed a directory"
        case (.listDirectory, true): "Listed directories"
        case (.runCommand, false): "Ran a command"
        case (.runCommand, true): "Ran commands"
        case (.runScript, false): "Ran a script"
        case (.runScript, true): "Ran scripts"
        case (.search, false): "Ran a search"
        case (.search, true): "Ran searches"
        case (.fetchWebPage, false): "Fetched a web page"
        case (.fetchWebPage, true): "Fetched web pages"
        case (.useApp, false): "Used an app"
        case (.useApp, true): "Used apps"
        case (.controlComputer, _): "Controlled the computer"
        case (.takeScreenshot, false): "Took a screenshot"
        case (.takeScreenshot, true): "Took screenshots"
        case (.createImage, false): "Created an image"
        case (.createImage, true): "Created images"
        case (.createVideo, false): "Created a video"
        case (.createVideo, true): "Created videos"
        case (.createAudio, false): "Created audio"
        case (.createAudio, true): "Created audio clips"
        case (.loadSkill, false): "Loaded a skill"
        case (.loadSkill, true): "Loaded skills"
        case (.askQuestion, false): "Asked a question"
        case (.askQuestion, true): "Asked questions"
        case (.checkSchedule, _): "Checked scheduled tasks"
        case (.changeSchedule, false): "Changed a scheduled task"
        case (.changeSchedule, true): "Changed scheduled tasks"
        }
        return String(localized: resource)
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

    static func fetchRecents() -> FetchDescriptor<Chat> {
        var descriptor = FetchDescriptor<Chat>(
            predicate: #Predicate { $0.project == nil })
        descriptor.sortBy = [.init(\.createdAt, order: .reverse)]
        return descriptor
    }
}
