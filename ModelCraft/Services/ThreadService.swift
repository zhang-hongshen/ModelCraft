//
//  ThreadService.swift
//  ModelCraft
//
//  Created by Hongshen on 11/1/26.
//

import SwiftUI
import SwiftData


@MainActor
@Observable
final class ThreadService {

    let interactionCoordinator: UserInteractionCoordinator
    private let executor: AgentExecutor

    private var currentTask: Task<Void, any Error>? = nil
    private var executionTask: Task<Void, any Error>?
    private var immediateMessageID: UUID?
    private(set) var queuedMessages: [Message] = []

    var isRunning: Bool { currentTask != nil }

    private var metadataTask: Task<Void, Never>? = nil
    private var currentRequestID: UUID?

    private(set) var isCompacting = false

    private static let compressionTrigger = 0.75

    /// An unattended service runs with nobody present, as scheduled runs do: questions and
    /// actions that need approval fail instead of waiting.
    init(isUnattended: Bool = false) {
        let interactionCoordinator = UserInteractionCoordinator()
        self.interactionCoordinator = interactionCoordinator
        self.executor = AgentExecutor(
            interactionCoordinator: interactionCoordinator,
            isUnattended: isUnattended)
    }

    private func cancelCurrentGeneration() async {
        guard let task = currentTask else { return }
        let requestID = currentRequestID
        task.cancel()
        interactionCoordinator.cancel()
        _ = try? await task.value
        guard currentRequestID == requestID else { return }
        currentRequestID = nil
    }

    func enqueue(_ message: Message) {
        queuedMessages.append(message)
    }

    func removeQueuedMessage(_ message: Message) {
        queuedMessages.removeAll { $0.id == message.id }
    }

    /// Cancels only the executor, preserving the request and its Ticket for re-reasoning.
    func sendQueuedMessageImmediately(_ message: Message) {
        guard isRunning,
              queuedMessages.contains(where: { $0.id == message.id }) else { return }
        immediateMessageID = message.id
        executionTask?.cancel()
        interactionCoordinator.cancel()
    }

    private func insertQueuedMessages(thread: Thread, ticket: Ticket) throws {
        let messages = immediateMessageID.map { id in
            queuedMessages.filter { $0.id == id }
        } ?? queuedMessages
        guard !messages.isEmpty else {
            immediateMessageID = nil
            return
        }
        let context = ModelContainer.shared.mainContext
        let ticket = thread.activeTicket ?? ticket
        // Leave queue drafts untouched until all conversation and Ticket links save.
        var inserted: [Message] = []
        for draft in messages {
            let message = Message(
                role: .user, thread: thread, content: draft.content, files: draft.files)
            ticket.append(message)
            context.insert(message)
            inserted.append(message)
        }
        let previousStatus = ticket.status
        let previousUpdate = ticket.updatedAt
        ticket.update(.working, progress: ticket.progress)
        do {
            try context.save()
        } catch {
            ticket.status = previousStatus
            ticket.updatedAt = previousUpdate
            thread.deleteMessages(inserted)
            throw error
        }
        let ids = Set(messages.map(\.id))
        queuedMessages.removeAll { ids.contains($0.id) }
        immediateMessageID = nil
    }

    func deleteThread(_ thread: Thread) {
        thread.deleteDirectory()
        ModelContainer.shared.mainContext.delete(thread)
    }

    func createThread(project: Project? = nil) -> Thread {
        let thread = Thread(project: project)
        ModelContainer.shared.mainContext.persist(thread)
        return thread
    }

    func sendMessage(
        model: LocalModel,
        thread: Thread,
        message: Message,
    ) async throws {
        metadataTask?.cancel()
        metadataTask = nil
        if isRunning {
            if queuedMessages.contains(where: { $0.id == message.id }) {
                sendQueuedMessageImmediately(message)
            } else {
                enqueue(message)
            }
            return
        }

        let requestID = UUID()
        currentRequestID = requestID

        let context = ModelContainer.shared.mainContext
        let queued = queuedMessages.contains { $0.id == message.id }
        let input = queued
            ? Message(role: .user, content: message.content, files: message.files)
            : message
        if input.thread == nil {
            input.parentID = thread.leafMessage?.id
            input.thread = thread
        }
        context.insert(input)
        do {
            try context.save()
        } catch {
            if queued { thread.deleteMessages([input]) }
            throw error
        }
        removeQueuedMessage(message)
        let generationTask = Task {
            try await runTickets(model: model, thread: thread, message: input)
        }
        currentTask = generationTask
        do {
            try await withTaskCancellationHandler {
                try await generationTask.value
            } onCancel: {
                generationTask.cancel()
            }
        } catch {
            if currentRequestID == requestID {
                thread.settleInterruptedMessages()
            }
            throw error
        }
        guard currentRequestID == requestID else { return }
        metadataTask = Task(priority: .background) { @MainActor in
            do {
                try Task.checkCancellation()
                try await self.generateTitleIfNeeded(model: model, thread: thread)
            } catch is CancellationError {
                // Expected when a new request supersedes background metadata.
            } catch {
                // Metadata is best effort and must not affect the thread turn.
            }
        }
    }

    func resendMessage(
        model: LocalModel,
        thread: Thread,
        message: Message
    ) async throws {
        await cancelCurrentGeneration()
        let conversation = thread.conversation
        guard let index = conversation.firstIndex(where: { $0.id == message.id }) else { return }
        thread.deleteMessages(Array(conversation[(index+1)...]))
        thread.discardStaleSummary()
        // A resend starts from the retained thread, without memories of discarded work.
        thread.activeTicket = nil
        try await sendMessage(
            model: model,
            thread: thread,
            message: message)
    }

    /// Restores a user turn to a draft and discards that turn and its following messages.
    func rewindMessage(thread: Thread, message: Message) async throws -> Message? {
        await stopGenerating(thread: thread)
        let conversation = thread.conversation
        guard message.role == .user,
              let index = conversation.firstIndex(where: { $0.id == message.id })
        else { return nil }
        let draft = Message(role: .user, content: message.content)
        draft.addFiles(message.files)
        thread.deleteMessages(Array(conversation[index...]))
        thread.discardStaleSummary()
        thread.activeTicket = nil
        thread.tokenCount = 0
        try ModelContainer.shared.mainContext.save()
        return draft
    }

    func compactContext(model: LocalModel, thread: Thread) async throws {
        isCompacting = true
        defer { isCompacting = false }
        try await AgentMemory.compact(model: model, thread: thread, ticket: thread.activeTicket)
        thread.tokenCount = try await LMService.shared.tokenCount(
            model: model, messages: AgentMemory.prompt(thread: thread, ticket: thread.activeTicket),
            tools: ToolDefinition.allToolSchema(for: thread))
    }

    private func runTickets(model: LocalModel, thread: Thread, message: Message) async throws {
        // End queue admission in the same main-actor turn as Ticket settlement.
        defer {
            executionTask = nil
            immediateMessageID = nil
            currentTask = nil
        }
        let context = ModelContainer.shared.mainContext
        if thread.activeTicket == nil {
            thread.settleInterruptedMessages()
            let ticket = Ticket(goal: message.content, thread: thread)
            context.insert(ticket)
            AgentMemory.seed(ticket, from: thread)
            thread.activeTicket = ticket
        }
        while let ticket = thread.activeTicket {
            try Task.checkCancellation()
            guard !ticket.isExecuting else { throw TaskExecutionError.alreadyRunning }
            ticket.append(message)
            ticket.isExecuting = true
            ticket.executionThread = thread
            ticket.modelID = model.id
            ticket.startedAt = .now
            ticket.endedAt = nil
            ticket.update(.working, progress: ticket.progress.isEmpty
                ? String(localized: "Execution started.") : ticket.progress)
            let firstExecutionEvent = ticket.eventIDs.count
            do {
                try context.save()
                while true {
                    let execution = Task {
                        try await self.executor.run(
                            model: model, thread: thread, ticket: ticket,
                            hasQueuedMessages: { !self.queuedMessages.isEmpty },
                            insertQueuedMessages: {
                                try self.insertQueuedMessages(thread: thread, ticket: ticket)
                            }, prepareMessages: {
                                var prompt = AgentMemory.prompt(thread: thread, ticket: ticket)
                                let count = try await LMService.shared.tokenCount(
                                    model: model, messages: prompt, tools: ToolDefinition.allToolSchema(for: thread))
                                if count >= Int(Self.compressionTrigger * Double(model.contextWindow)) {
                                    self.isCompacting = true
                                    defer { self.isCompacting = false }
                                    try await AgentMemory.compact(model: model, thread: thread, ticket: ticket)
                                    prompt = AgentMemory.prompt(thread: thread, ticket: ticket)
                                }
                                try Task.checkCancellation()
                                return prompt
                            })
                    }
                    executionTask = execution
                    if immediateMessageID != nil { execution.cancel() }
                    do {
                        try await withTaskCancellationHandler {
                            try await execution.value
                        } onCancel: {
                            execution.cancel()
                        }
                    } catch {
                        executionTask = nil
                        try Task.checkCancellation()
                        guard execution.isCancelled, immediateMessageID != nil else { throw error }
                        thread.settleInterruptedMessages()
                        try insertQueuedMessages(thread: thread, ticket: ticket)
                        if thread.activeTicket?.id != ticket.id { break }
                        continue
                    }
                    executionTask = nil
                    try Task.checkCancellation()
                    // Cover input arriving as the executor returns from its final boundary.
                    if !queuedMessages.isEmpty {
                        try insertQueuedMessages(thread: thread, ticket: ticket)
                        if thread.activeTicket?.id == ticket.id { continue }
                    }
                    break
                }
                try Task.checkCancellation()
                let switchedTask = thread.activeTicket?.id != ticket.id
                let status = ticket.status == .working ? TicketStatus.waiting : ticket.status
                let reply = ticket.history.dropFirst(firstExecutionEvent)
                    .last { $0.role == .assistant && !$0.content.isEmpty }?.content
                // A structured progress update remains authoritative for handoff states.
                ticket.finish(status, progress: switchedTask || ticket.status != .working ? nil : reply)
                try context.save()
                if !switchedTask { break }
            } catch {
                thread.settleInterruptedMessages()
                ticket.finish(Task.isCancelled ? .paused : .failed,
                              progress: Task.isCancelled
                                ? String(localized: "Execution stopped. Continue when you are ready.")
                                : error.localizedDescription)
                try context.save()
                throw error
            }
        }
    }

    private func generateTitleIfNeeded (model: LocalModel, thread: Thread) async throws {
        if thread.title != nil {
            return
        }
        let prompt = PromptBuilder.generateTitle(messages: thread.conversation)
        thread.title = try await LMService.shared.generateAuxiliary(
            model: model,
            messages: prompt)
    }

    func stopGenerating(thread: Thread) async {
        metadataTask?.cancel()
        metadataTask = nil
        await cancelCurrentGeneration()
        if !isRunning { thread.settleInterruptedMessages() }
    }

}

private enum TaskExecutionError: LocalizedError {
    case alreadyRunning

    var errorDescription: String? { String(localized: "This task is already running.") }
}

@MainActor
@Observable
final class UserInteractionCoordinator {

    struct PendingUserInput: Identifiable, Sendable {
        let id = UUID()
        let request: RequestUserInput
    }

    struct PendingApproval: Identifiable, Sendable {
        let id = UUID()
        let request: ToolApprovalRequest
    }

    enum PendingInteraction: Identifiable, Sendable {
        case userInput(PendingUserInput)
        case approval(PendingApproval)

        var id: UUID {
            switch self {
            case .userInput(let pendingUserInput):
                pendingUserInput.id
            case .approval(let pendingApproval):
                pendingApproval.id
            }
        }
    }

    private(set) var pendingInteraction: PendingInteraction?
    @ObservationIgnored
    private var userInputContinuation: CheckedContinuation<RequestUserInputOutput, any Error>?
    @ObservationIgnored
    private var approvalContinuation: CheckedContinuation<ToolApprovalDecision, any Error>?

    func requestUserInput(_ request: RequestUserInput) async throws -> RequestUserInputOutput {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingInteraction = .userInput(PendingUserInput(request: request))
                userInputContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    func requestApproval(_ request: ToolApprovalRequest) async throws -> ToolApprovalDecision {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingInteraction = .approval(PendingApproval(request: request))
                approvalContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    func submitUserInput(_ answers: [UserInputAnswer]) {
        let continuation = userInputContinuation
        userInputContinuation = nil
        pendingInteraction = nil
        continuation?.resume(returning: RequestUserInputOutput(answers: answers))
    }

    func resolveApproval(_ decision: ToolApprovalDecision) {
        let continuation = approvalContinuation
        approvalContinuation = nil
        pendingInteraction = nil
        continuation?.resume(returning: decision)
    }

    func cancel() {
        let userInputContinuation = userInputContinuation
        let approvalContinuation = approvalContinuation
        self.userInputContinuation = nil
        self.approvalContinuation = nil
        pendingInteraction = nil
        userInputContinuation?.resume(throwing: CancellationError())
        approvalContinuation?.resume(throwing: CancellationError())
    }
}
