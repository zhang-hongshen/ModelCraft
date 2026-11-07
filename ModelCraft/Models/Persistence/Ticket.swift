import Foundation
import SwiftData

/// A task belongs to its originating thread; executions can continue in another thread.
@Model
final class Ticket {
    @Attribute(.unique) var id = UUID()
    var createdAt = Date.now
    var goal: String
    var title: String
    var status: TicketStatus = TicketStatus.waiting
    var memory: String = ""
    var thread: Chat?
    var activeThreads: [Chat] = []
    @Relationship(deleteRule: .cascade) var session: ExecutorSession?
    @Relationship(deleteRule: .cascade, inverse: \Assignment.ticket)
    var assignments: [Assignment] = []

    init(goal: String, thread: Chat, title: String? = nil) {
        self.goal = goal
        let firstLine = goal.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).first
        self.title = title ?? firstLine.map { String($0.prefix(60)) } ?? String(localized: "Untitled Task")
        self.thread = thread
        self.session = ExecutorSession()
    }

    var runningAssignment: Assignment? { assignments.first { $0.endedAt == nil } }

    var latestReport: TaskReport? {
        assignments.flatMap(\.reports).max { $0.createdAt < $1.createdAt }
    }

    static func fetch(chat: Chat?, project: Project?) -> FetchDescriptor<Ticket> {
        let predicate: Predicate<Ticket>
        if let projectID = project?.id {
            predicate = #Predicate { $0.thread?.project?.id == projectID }
        } else if let chatID = chat?.id {
            predicate = #Predicate { $0.thread?.id == chatID }
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

@Model
final class ExecutorSession {
    @Attribute(.unique) var id = UUID()
    /// A checkpoint replaces only this session's transcript prefix, never task memory.
    var checkpoint: String?
    var checkpointThroughID: UUID?
    /// Input snapshots and shared chat messages have one durable protocol order.
    var eventIDs: [UUID] = []
    @Relationship(inverse: \Message.executorSessions) var messages: [Message] = []
    @Relationship(deleteRule: .cascade, inverse: \TaskInput.session)
    var inputs: [TaskInput] = []

    init() {}

    var history: [Message] {
        let inputMessages = inputs.map { input in
            let message = Message(role: .user, content: input.content, files: input.files)
            message.id = input.id
            message.createdAt = input.createdAt
            return message
        }
        let events = Dictionary(uniqueKeysWithValues: (messages + inputMessages).map { ($0.id, $0) })
        return eventIDs.compactMap { events[$0] }
    }

    var context: [Message] {
        let history = history
        guard let checkpointThroughID,
              let index = history.firstIndex(where: { $0.id == checkpointThroughID })
        else { return history }
        return Array(history.dropFirst(index + 1))
    }

    func discardCheckpoint() {
        checkpoint = nil
        checkpointThroughID = nil
    }
}

@Model
final class Assignment {
    @Attribute(.unique) var id = UUID()
    var startedAt = Date.now
    var endedAt: Date?
    var modelID: String
    var ticket: Ticket?
    var thread: Chat?
    @Relationship(deleteRule: .cascade, inverse: \TaskReport.assignment)
    var reports: [TaskReport] = []

    init(ticket: Ticket, thread: Chat, modelID: String) {
        self.ticket = ticket
        self.thread = thread
        self.modelID = modelID
    }

    var latestReport: TaskReport? { reports.max { $0.createdAt < $1.createdAt } }

    @MainActor
    func report(_ status: TicketStatus, content: String) {
        let report = TaskReport(status: status, content: content, assignment: self)
        ModelContainer.shared.mainContext.insert(report)
        ticket?.status = status
    }

    @MainActor
    func finish(_ status: TicketStatus, content: String) throws {
        report(status, content: content)
        endedAt = .now
        try ModelContainer.shared.mainContext.save()
    }

    /// A persisted running assignment cannot still own execution after process launch.
    @MainActor
    static func recoverInterrupted() throws {
        let context = ModelContainer.shared.mainContext
        let assignments = try context.fetch(FetchDescriptor<Assignment>(
            predicate: #Predicate { $0.endedAt == nil }))
        for assignment in assignments {
            assignment.thread?.settleInterruptedMessages()
            try assignment.finish(.paused, content:
                String(localized: "Execution was interrupted by an app restart. Check recorded tool results and current files before repeating any side effect. Continue when the user requests it."))
        }
    }
}

/// Inputs are immutable snapshots: a resumed task does not borrow another thread's summary.
@Model
final class TaskInput {
    @Attribute(.unique) var id = UUID()
    var createdAt = Date.now
    var sourceMessageID: UUID
    var content: String
    var files: [URL]
    var assignmentID: UUID?
    var consumedAt: Date?
    var session: ExecutorSession?

    init(message: Message, session: ExecutorSession, assignmentID: UUID? = nil) {
        sourceMessageID = message.id
        content = message.content
        files = message.files
        self.assignmentID = assignmentID
        self.session = session
        session.eventIDs.append(id)
    }
}

@Model
final class TaskReport {
    @Attribute(.unique) var id = UUID()
    var createdAt = Date.now
    var status: TicketStatus
    var content: String
    var assignment: Assignment?

    init(status: TicketStatus, content: String, assignment: Assignment) {
        self.status = status
        self.content = content
        self.assignment = assignment
    }
}
