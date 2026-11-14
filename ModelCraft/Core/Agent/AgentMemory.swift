import Foundation
import SwiftData
import MLXLMCommon

/// One policy for memory assembly and compaction; values stay on their scoped owners.
@MainActor
enum AgentMemory {
    static func system(thread: Thread, ticket: Ticket? = nil) -> Message {
        PromptBuilder.system(
            project: thread.project,
            summary: ticket == nil ? thread.summary : nil,
            ticket: ticket)
    }

    static func context(thread: Thread, ticket: Ticket? = nil) -> [Message] {
        if let ticket {
            let history = ticket.history
            guard let boundary = ticket.checkpointThroughID,
                  let index = history.firstIndex(where: { $0.id == boundary }) else { return history }
            return Array(history.dropFirst(index + 1))
        }
        let history = thread.conversation
        let index = thread.summaryBoundaryID.flatMap { id in history.firstIndex { $0.id == id } } ?? 0
        return Array(history.dropFirst(index))
    }

    static func prompt(thread: Thread, ticket: Ticket? = nil) -> [MLXLMCommon.Chat.Message] {
        LMService.shared.protocolMessages([system(thread: thread, ticket: ticket)] + context(thread: thread, ticket: ticket))
    }

    /// The first task in a thread starts with its existing conversation, including imports.
    static func seed(_ ticket: Ticket, from thread: Thread) {
        let history = thread.conversation
        ticket.messages = history
        ticket.eventIDs = history.map(\.id)
        if let boundary = thread.summaryBoundaryID,
           let index = history.firstIndex(where: { $0.id == boundary }), index > 0 {
            ticket.checkpoint = thread.summary
            ticket.checkpointThroughID = history[index - 1].id
        }
    }

    static func discardCheckpoint(_ ticket: Ticket) {
        ticket.checkpoint = nil
        ticket.checkpointThroughID = nil
    }

    /// Compress only a completed prefix, retaining an intact protocol tail and originals.
    static func compact(model: LocalModel, thread: Thread, ticket: Ticket? = nil) async throws {
        let messages = context(thread: thread, ticket: ticket)
        let latestUser = messages.lastIndex { $0.role == .user }
        let endIndex: Int
        if ticket != nil {
            endIndex = latestUser.flatMap { $0 > 0 ? $0 : nil } ?? (messages.count - 1)
        } else {
            // Thread summaries use a first-uncovered-message boundary.
            endIndex = latestUser ?? 0
        }
        guard endIndex > 0 else { return }
        let prefix = Array(messages.prefix(endIndex))
        guard !prefix.contains(where: { $0.status == .generating || $0.status == .new }) else { return }
        let previous = ticket == nil ? thread.summary : ticket?.checkpoint
        var parts = previous.map { ["<previous_summary>\($0)</previous_summary>"] } ?? []
        parts.append(PromptBuilder.compressionText(prefix))
        let summary = try await LMService.shared.generateAuxiliary(
            model: model,
            messages: PromptBuilder.summarize(conversation: parts.joined(separator: "\n")))
        try Task.checkCancellation()
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryError.emptyCheckpoint
        }
        if let ticket {
            ticket.checkpoint = summary
            ticket.checkpointThroughID = prefix.last?.id
        } else {
            thread.summary = summary
            thread.summaryBoundaryID = messages[endIndex].id
        }
        try ModelContainer.shared.mainContext.save()
    }
}

private enum MemoryError: LocalizedError {
    case emptyCheckpoint
    var errorDescription: String? { String(localized: "The model returned an empty context checkpoint.") }
}
