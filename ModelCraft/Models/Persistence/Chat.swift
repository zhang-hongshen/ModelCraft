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
    
    /// The first message after the part of the conversation `summary` replaces.
    var summaryBoundaryID: UUID? = nil

    var project: Project? = nil

    /// The schedule whose run created this chat.
    var schedule: Schedule? = nil
    
    @Relationship(deleteRule: .cascade, inverse: \Message.chat)
    var messages: [Message] = []
    
    var tokenCount: Int = 0

    private var _toolAuthorization: String?

    /// What the user chose to always allow in this conversation.
    @Transient var toolAuthorization: ToolAuthorizationContext? {
        get {
            guard let data = _toolAuthorization?.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ToolAuthorizationContext.self, from: data)
        }

        set {
            guard let newValue else {
                _toolAuthorization = nil
                return
            }

            if let data = try? JSONEncoder().encode(newValue) {
                _toolAuthorization = String(data: data, encoding: .utf8)
            } else {
                _toolAuthorization = nil
            }
        }
    }

    init(title: String? = nil, project: Project? = nil) {
        self.title = title
        self.project = project
    }
    
}

extension Chat {

    /// The chat's own folder for attachments and generated media. Outside a project it is
    /// also the working directory for tools.
    var directory: URL {
        URL.appSupportDirectory.appending(
            path: "Chats/\(id.uuidString)",
            directoryHint: .isDirectory)
    }

    /// Removes the chat's folder; called wherever a chat is deleted.
    func deleteDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }

    var status: MessageStatus {
        leafMessage?.status ?? .generated
    }

    /// The latest message nothing follows; the conversation ends here.
    var leafMessage: Message? {
        let parentIDs = Set(messages.compactMap(\.parentID))
        return messages
            .filter { !parentIDs.contains($0.id) }
            .max { $0.createdAt < $1.createdAt }
    }

    /// The conversation from its first message to the leaf, found by following each
    /// message's `parentID` up from the leaf.
    var conversation: [Message] {
        let messagesByID = Dictionary(messages.map { ($0.id, $0) }) { first, _ in first }
        var conversation: [Message] = []
        var message = leafMessage
        while let current = message {
            conversation.append(current)
            message = current.parentID.flatMap { messagesByID[$0] }
        }
        return conversation.reversed()
    }

    var currentGeneratingAssistantMessage: Message? {
        conversation.last { $0.role == .assistant && $0.status == .generating }
    }

    var isGenerating: Bool {
        leafMessage?.status == .generating
    }

    /// Removes the messages from the chat right away, so the next message's parent is read
    /// without them, and deletes them. A message that followed a deleted one then follows
    /// what the deleted one followed, so the chain stays unbroken.
    @MainActor
    func deleteMessages(_ messages: [Message]) {
        let parentIDs = Dictionary(messages.map { ($0.id, $0.parentID) }) { first, _ in first }
        self.messages.removeAll { parentIDs.keys.contains($0.id) }
        for message in self.messages {
            while let parentID = message.parentID, let grandparentID = parentIDs[parentID] {
                message.parentID = grandparentID
            }
        }
        ModelContainer.shared.mainContext.delete(messages)
    }

    /// The summary stops applying once its boundary message is gone, for example after a
    /// resend removed it.
    func discardStaleSummary() {
        guard let summaryBoundaryID,
              !messages.contains(where: { $0.id == summaryBoundaryID })
        else { return }
        self.summaryBoundaryID = nil
        summary = nil
    }

    /// Stores written before messages recorded their parent kept each chat in `createdAt`
    /// order. Links those chats' messages in that order; a chat whose messages are linked
    /// has a single root and is left alone.
    @MainActor
    static func linkLegacyMessages() {
        let context = ModelContainer.shared.mainContext
        let roots = (try? context.fetch(FetchDescriptor<Message>(
            predicate: #Predicate { $0.parentID == nil }))) ?? []
        let legacyChats = Dictionary(grouping: roots.compactMap(\.chat), by: \.id)
            .values
            .filter { $0.count > 1 }
            .map { $0[0] }
        guard !legacyChats.isEmpty else { return }
        for chat in legacyChats {
            let messages = chat.messages.sorted { $0.createdAt < $1.createdAt }
            for (parent, message) in zip(messages, messages.dropFirst()) {
                message.parentID = parent.id
            }
            // Its old boundary was a position that did not survive the migration.
            if chat.summaryBoundaryID == nil {
                chat.summary = nil
            }
        }
        try? context.save()
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
    case checkModelCraft, changeModelCraft

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
        case (.checkModelCraft, _): "Checked ModelCraft"
        case (.changeModelCraft, _): "Changed ModelCraft"
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
