import Foundation
import SwiftData

/// A task owns its recoverable context; Thread continues to own the visible messages.
@Model
final class Ticket {
    @Attribute(.unique) var id = UUID()
    var createdAt = Date.now
    var updatedAt = Date.now
    var goal: String
    var title: String
    var status: TicketStatus = TicketStatus.waiting
    var progress: String = ""
    var memory: String = ""
    var thread: Thread?
    var activeThreads: [Thread] = []

    var checkpoint: String?
    var checkpointThroughID: UUID?
    var eventIDs: [UUID] = []
    @Relationship(inverse: \Message.tickets) var messages: [Message] = []

    /// Execution ownership is independent of a model-reported task status.
    var isExecuting = false
    var executionThread: Thread?
    var modelID: String?
    var startedAt: Date?
    var endedAt: Date?

    init(goal: String, thread: Thread, title: String? = nil) {
        self.goal = goal
        let firstLine = goal.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).first
        self.title = title ?? firstLine.map { String($0.prefix(60)) } ?? String(localized: "Untitled Task")
        self.thread = thread
    }

    var history: [Message] {
        let events = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        return eventIDs.compactMap { events[$0] }
    }

    /// A resumed input may already have been attached by the task tool before handoff.
    func append(_ message: Message) {
        guard !eventIDs.contains(message.id) else { return }
        messages.append(message)
        eventIDs.append(message.id)
    }

    func update(_ status: TicketStatus, progress: String) {
        self.status = status
        self.progress = progress
        updatedAt = .now
    }

    func finish(_ status: TicketStatus, progress: String? = nil) {
        isExecuting = false
        endedAt = .now
        self.status = status
        if let progress {
            if (status == .paused || status == .failed) && !self.progress.isEmpty {
                self.progress += "\n\n" + progress
            } else {
                self.progress = progress
            }
        }
        updatedAt = .now
    }

    @MainActor
    static func recoverInterrupted() throws {
        let context = ModelContainer.shared.mainContext
        let tickets = try context.fetch(FetchDescriptor<Ticket>(
            predicate: #Predicate { $0.isExecuting }))
        for ticket in tickets {
            ticket.executionThread?.settleInterruptedMessages()
            ticket.finish(.paused, progress: String(localized: "Execution was interrupted by an app restart. Check recorded tool results and current files before repeating any side effect. Continue when the user requests it."))
        }
        try context.save()
    }

    static func fetch(thread: Thread?, project: Project?) -> FetchDescriptor<Ticket> {
        let predicate: Predicate<Ticket>
        if let projectID = project?.id {
            predicate = #Predicate { $0.thread?.project?.id == projectID }
        } else if let threadID = thread?.id {
            predicate = #Predicate { $0.thread?.id == threadID }
        } else {
            predicate = #Predicate { _ in false }
        }
        return FetchDescriptor(predicate: predicate, sortBy: [.init(\.createdAt, order: .reverse)])
    }
}

enum TicketStatus: String, Codable, CaseIterable {
    case working, waiting, completed, blocked, failed, paused

    var title: LocalizedStringResource {
        switch self {
        case .working: "Working"
        case .waiting: "Ready to Continue"
        case .completed: "Completed"
        case .blocked: "Blocked"
        case .failed: "Failed"
        case .paused: "Paused"
        }
    }

    var symbol: String {
        switch self {
        case .working: "arrow.triangle.2.circlepath"
        case .waiting: "clock"
        case .completed: "checkmark.circle"
        case .blocked: "exclamationmark.circle"
        case .failed: "xmark.circle"
        case .paused: "pause.circle"
        }
    }
}
