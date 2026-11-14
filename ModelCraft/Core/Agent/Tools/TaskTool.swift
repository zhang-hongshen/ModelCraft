import Foundation
import SwiftData
import MLXLMCommon

enum TaskTool {
    static func task(threadID: UUID) -> Tool<TaskToolInput, TaskToolOutput> {
        Tool(
            name: ToolNames.task,
            description: """
            Manage the local task behind this conversation. The current task and its executor context persist across app restarts. Ordinary follow-ups continue it automatically.
            list finds tasks in this project (outside projects, this conversation only). read retrieves a task's goal, state, progress, task memory, execution checkpoint and a page of its original transcript, including content omitted by compaction.
            start creates an independent task only when the user requests separate work beyond the current goal; goal is required. resume switches to a listed ticket_id only on the user's request to continue that task, reusing its checkpoint and original messages and delivering the current user request there. A running task cannot be resumed elsewhere. Starting or resuming hands execution to that task immediately; the next model step receives its context and should fulfill the delivered request rather than route it again. These actions do not expand file or application permissions.
            report updates the current task's status and latest progress directly; status and content are required. Use working for progress, waiting when the current turn ends with more work possible, completed only when the requested outcome is achieved, blocked for a missing decision/resource, and failed for execution failure. memory optionally replaces task memory with concise facts, decisions, verified actions and remaining work. Record this during substantial work, before detailed evidence leaves context. Do not promote task summaries into project memory.
            """,
            parameters: [
                .required("action", type: .string, description: "The operation to perform.", extraProperties: ["enum": ["list", "read", "start", "resume", "report"]]),
                .optional("ticket_id", type: .string, description: "A task ID from list; required for resume. read defaults to the current task."),
                .optional("goal", type: .string, description: "start only: the user's requested goal and scope."),
                .optional("status", type: .string, description: "report only: the task's actual state.", extraProperties: ["enum": ["working", "waiting", "completed", "blocked", "failed"]]),
                .optional("content", type: .string, description: "report only: progress, verified result, blocker, or failure and the remaining work."),
                .optional("memory", type: .string, description: "report only: complete replacement of task memory. Empty clears it; omitted preserves it."),
                .optional("offset", type: .int, description: "read only: zero-based transcript offset, default 0."),
                .optional("limit", type: .int, description: "read only: number of transcript messages, 1–50, default 20."),
            ]
        ) { input in
            try await MainActor.run {
                let context = ModelContainer.shared.mainContext
                guard let thread = try context.fetch(FetchDescriptor<Thread>(
                    predicate: #Predicate { $0.id == threadID })).first else {
                    throw TaskToolError.invalidRequest("Conversation no longer exists.")
                }
                let tickets = try context.fetch(Ticket.fetch(thread: thread, project: thread.project))
                if input.action == "list" {
                    return TaskToolOutput(content: tickets.map {
                        "\($0.id) [\($0.status.rawValue)] \($0.title)"
                    }.joined(separator: "\n"))
                }
                if input.action == "start" {
                    guard let goal = input.goal, !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw TaskToolError.invalidRequest("start requires a nonempty goal.")
                    }
                    let ticket = Ticket(goal: goal, thread: thread)
                    context.insert(ticket)
                    if let message = thread.conversation.last(where: { $0.role == .user }) {
                        ticket.append(message)
                    }
                    thread.activeTicket = ticket
                    try context.save()
                    return TaskToolOutput(content: "Started task \(ticket.id): \(goal)")
                }
                let ticket = input.ticketID.flatMap { id in tickets.first { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame } }
                    ?? (input.ticketID == nil ? thread.activeTicket : nil)
                guard let ticket else { throw TaskToolError.invalidRequest("Task not found in this conversation or project.") }
                switch input.action {
                case "resume":
                    guard input.ticketID != nil else {
                        throw TaskToolError.invalidRequest("resume requires ticket_id.")
                    }
                    if ticket.id != thread.activeTicket?.id {
                        guard !ticket.isExecuting else {
                            throw TaskToolError.invalidRequest("This task is already running.")
                        }
                        if let message = thread.conversation.last(where: { $0.role == .user }) {
                            ticket.append(message)
                        }
                        thread.activeTicket = ticket
                        try context.save()
                    }
                case "report":
                    guard ticket.id == thread.activeTicket?.id,
                          let status = input.status, status != .paused,
                          let content = input.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          ticket.isExecuting else {
                        throw TaskToolError.invalidRequest("report requires the running task, status and content.")
                    }
                    if let memory = input.memory { ticket.memory = memory }
                    ticket.update(status, progress: content)
                    try context.save()
                case "read": break
                default: throw TaskToolError.invalidRequest("Unknown task action.")
                }
                if input.action != "read" {
                    return TaskToolOutput(content: "Task \(ticket.id): \(ticket.status.rawValue)")
                }
                let history = ticket.history
                let offset = input.offset ?? 0
                let limit = input.limit ?? 20
                guard offset >= 0, (1...50).contains(limit) else {
                    throw TaskToolError.invalidRequest("offset must be nonnegative and limit must be 1–50.")
                }
                return TaskToolOutput(content: """
                    Ticket: \(ticket.id)
                    Title: \(ticket.title)
                    Goal: \(ticket.goal)
                    Status: \(ticket.status.rawValue)
                    Memory: \(ticket.memory)
                    Progress: \(ticket.progress)
                    Checkpoint: \(ticket.checkpoint ?? "")
                    Transcript (\(history.count) messages, offset \(offset)):
                    \(PromptBuilder.compressionText(Array(history.dropFirst(offset).prefix(limit))))
                    """)
            }
        }
    }
}

struct TaskToolInput: Codable {
    let action: String
    let ticketID: String?
    let goal: String?
    let status: TicketStatus?
    let content: String?
    let memory: String?
    let offset: Int?
    let limit: Int?

    enum CodingKeys: String, CodingKey {
        case action, goal, status, content, memory, offset, limit
        case ticketID = "ticket_id"
    }
}

struct TaskToolOutput: Codable { let content: String }

private enum TaskToolError: LocalizedError {
    case invalidRequest(String)
    var errorDescription: String? {
        switch self { case .invalidRequest(let message): message }
    }
}
