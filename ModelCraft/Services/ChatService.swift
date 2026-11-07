//
//  ChatService.swift
//  ModelCraft
//
//  Created by Hongshen on 11/1/26.
//

import SwiftUI
import SwiftData
import MLXLMCommon
import Tokenizers


@MainActor
@Observable
final class ChatService {
    
    let interactionCoordinator: UserInteractionCoordinator
    private let executor: AgentExecutor
    
    private var currentTask: Task<Void, any Error>? = nil
    private var metadataTask: Task<Void, Never>? = nil
    private var currentRequestID: UUID?

    private(set) var isCompacting = false
    private(set) var executingChatID: UUID?

    var isRunning: Bool { currentTask != nil }

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
        _ = try? await task.value
        guard currentRequestID == requestID else { return }
        currentTask = nil
        currentRequestID = nil
        executingChatID = nil
    }
    
    func deleteChat(_ chat: Chat) {
        chat.deleteDirectory()
        ModelContainer.shared.mainContext.delete(chat)
    }
    
    func createChat(project: Project? = nil) -> Chat {
        let chat = Chat(project: project)
        ModelContainer.shared.mainContext.persist(chat)
        return chat
    }

    func startTask(title: String, goal: String, model: LocalModel, chat: Chat) async throws {
        guard !isRunning, !isCompacting else { throw TaskExecutionError.alreadyRunning }
        let ticket = Ticket(goal: goal, thread: chat, title: title)
        ModelContainer.shared.mainContext.insert(ticket)
        chat.activeTicket = ticket
        try ModelContainer.shared.mainContext.save()
        try await sendMessage(model: model, chat: chat,
                              message: Message(role: .user, chat: chat, content: goal))
    }

    func resumeTask(_ ticket: Ticket, content: String, model: LocalModel, chat: Chat) async throws {
        guard !isRunning, !isCompacting, ticket.runningAssignment == nil else {
            throw TaskExecutionError.alreadyRunning
        }
        chat.activeTicket = ticket
        try ModelContainer.shared.mainContext.save()
        try await sendMessage(model: model, chat: chat,
                              message: Message(role: .user, chat: chat, content: content))
    }
    
    func sendMessage(
        model: LocalModel,
        chat: Chat,
        message: Message,
    ) async throws {
        metadataTask?.cancel()
        metadataTask = nil
        await cancelCurrentGeneration()

        let requestID = UUID()
        currentRequestID = requestID
        executingChatID = chat.id

        message.moveFiles(to: chat.directory)
        ModelContainer.shared.mainContext.persist(message)
        let generationTask = Task {
            try await runAssignments(model: model, chat: chat, message: message)
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
                currentTask = nil
                executingChatID = nil
                chat.settleInterruptedMessages()
            }
            throw error
        }
        metadataTask = Task(priority: .background) { @MainActor in
            do {
                try Task.checkCancellation()
                try await self.generateTitleIfNeeded(model: model, chat: chat)
            } catch is CancellationError {
                // Expected when a new request supersedes background metadata.
            } catch {
                // Metadata is best effort and must not affect the chat turn.
            }
        }
        guard currentRequestID == requestID else { return }
        currentTask = nil
        executingChatID = nil
    }
    
    func resendMessage(
        model: LocalModel,
        chat: Chat,
        message: Message
    ) async throws {
        await cancelCurrentGeneration()
        let conversation = chat.conversation
        guard let index = conversation.firstIndex(where: { $0.id == message.id }) else { return }
        chat.deleteMessages(Array(conversation[(index+1)...]))
        chat.discardStaleSummary()
        // A resend starts from the retained thread, without memories of discarded work.
        chat.activeTicket = nil
        try await sendMessage(
            model: model,
            chat: chat,
            message: message)
    }

    /// Restores a user turn to a draft and discards that turn and its following messages.
    func rewindMessage(chat: Chat, message: Message) async throws -> Message? {
        await stopGenerating(chat: chat)
        let conversation = chat.conversation
        guard message.role == .user,
              let index = conversation.firstIndex(where: { $0.id == message.id })
        else { return nil }
        let draft = Message(role: .user, content: message.content)
        draft.addFiles(message.files)
        chat.deleteMessages(Array(conversation[index...]))
        chat.discardStaleSummary()
        chat.activeTicket = nil
        chat.tokenCount = 0
        try ModelContainer.shared.mainContext.save()
        return draft
    }

    func compactContext(
        model: LocalModel,
        chat: Chat
    ) async throws {
        if let session = chat.activeTicket?.session {
            try await compactSession(model: model, session: session)
            chat.tokenCount = try await LMService.shared.tokenCount(
                model: model, messages: buildPrompt(chat: chat), tools: availableTools(for: chat))
            return
        }
        let messages = chat.conversation
        let startIndex = summaryStartIndex(of: chat, in: messages)

        guard let endIndex = messages.indices.last(where: {
            $0 > startIndex && messages[$0].role == .user
        }) else {
            return
        }
        guard endIndex > startIndex else { return }
        
        isCompacting = true
        defer { isCompacting = false }

        let messagesToSummarize = Array(messages[startIndex..<endIndex])

        guard !messagesToSummarize.isEmpty,
              !messagesToSummarize.contains(where: { $0.status == .generating })
        else {
            return
        }

        let summary = try await summarize(
            model: model,
            previousSummary: chat.summary,
            messages: messagesToSummarize
        )

        chat.summary = summary
        chat.summaryBoundaryID = messages[endIndex].id
        try ModelContainer.shared.mainContext.save()
        
        chat.tokenCount = try await LMService.shared.tokenCount(
            model: model,
            messages: buildPrompt(
                chat: chat),
            tools: availableTools(for: chat))
    }

    private func runAssignments(model: LocalModel, chat: Chat, message: Message) async throws {
        let context = ModelContainer.shared.mainContext
        if chat.activeTicket == nil {
            chat.settleInterruptedMessages()
            let ticket = Ticket(goal: message.content, thread: chat)
            context.insert(ticket)
            chat.activeTicket = ticket
            // Adopt legacy history once. A newly started task does not inherit another
            // task's session or turn a thread checkpoint into task memory.
            let history = chat.conversation.filter { $0.id != message.id }
            ticket.session?.messages = history
            ticket.session?.eventIDs = history.map(\.id)
            if let boundary = chat.summaryBoundaryID,
               let index = history.firstIndex(where: { $0.id == boundary }), index > 0 {
                ticket.session?.checkpoint = chat.summary
                ticket.session?.checkpointThroughID = history[index - 1].id
            } else if chat.summaryBoundaryID == message.id, let last = history.last {
                ticket.session?.checkpoint = chat.summary
                ticket.session?.checkpointThroughID = last.id
            }
        }
        while let ticket = chat.activeTicket, let session = ticket.session {
            try Task.checkCancellation()
            guard !ticket.assignments.contains(where: { $0.endedAt == nil }) else {
                throw TaskExecutionError.alreadyRunning
            }
            let assignment = Assignment(ticket: ticket, thread: chat, modelID: model.id)
            context.insert(assignment)
            if !session.inputs.contains(where: { $0.sourceMessageID == message.id && $0.consumedAt == nil }) {
                context.insert(TaskInput(message: message, session: session, assignmentID: assignment.id))
            }
            let previousReport = ticket.assignments.flatMap(\.reports).max { $0.createdAt < $1.createdAt }
            assignment.report(.working, content: previousReport?.content ?? String(localized: "Execution started."))
            try context.save()
            do {
                try await executor.run(model: model, chat: chat, assignment: assignment) {
                    var prompt = self.buildPrompt(chat: chat, ticket: ticket)
                    let count = try await LMService.shared.tokenCount(
                        model: model, messages: prompt, tools: self.availableTools(for: chat))
                    if count >= Int(Self.compressionTrigger * Double(model.contextWindow)) {
                        try await self.compactSession(model: model, session: session)
                        prompt = self.buildPrompt(chat: chat, ticket: ticket)
                    }
                    try Task.checkCancellation()
                    for input in session.inputs where input.consumedAt == nil {
                        input.assignmentID = assignment.id
                        input.consumedAt = .now
                    }
                    try context.save()
                    return prompt
                }
                try Task.checkCancellation()
                let switchedTask = chat.activeTicket?.id != ticket.id
                let status = ticket.status == .working ? TicketStatus.waiting : ticket.status
                let reply = session.history.last(where: { $0.role == .assistant })?.content ?? ""
                try assignment.finish(status, content: switchedTask
                    ? "Execution handed off to the selected task." : reply)
                if !switchedTask { break }
            } catch {
                chat.settleInterruptedMessages()
                try assignment.finish(Task.isCancelled ? .paused : .failed,
                                      content: Task.isCancelled
                                        ? String(localized: "Execution stopped. Continue when you are ready.")
                                        : error.localizedDescription)
                throw error
            }
        }
    }

    private func compactSession(model: LocalModel, session: ExecutorSession) async throws {
        let messages = session.context
        // Keep a complete protocol tail; even a single long tool turn can compact.
        let latestUser = messages.lastIndex { $0.role == .user }
        let endIndex = latestUser.map { $0 > 0 ? $0 : messages.count - 1 }
            ?? (messages.count - 1)
        guard endIndex > 0 else { return }
        let prefix = Array(messages.prefix(endIndex))
        guard !prefix.contains(where: { $0.status == .generating || $0.status == .new }) else { return }
        isCompacting = true
        defer { isCompacting = false }
        let summary = try await summarize(model: model, previousSummary: session.checkpoint, messages: prefix)
        try Task.checkCancellation()
        session.checkpoint = summary
        session.checkpointThroughID = prefix.last?.id
        try ModelContainer.shared.mainContext.save()
    }
    
    private func generateTitleIfNeeded (model: LocalModel, chat: Chat) async throws {
        if chat.title != nil {
            return
        }
        let prompt = PromptBuilder.generateTitle(messages: chat.conversation)
        chat.title = try await LMService.shared.generateAuxiliary(
            model: model,
            messages: prompt)
    }
    
    func stopGenerating(chat: Chat) async {
        interactionCoordinator.cancel()
        metadataTask?.cancel()
        metadataTask = nil
        await cancelCurrentGeneration()
        chat.settleInterruptedMessages()
    }

    private func summarize(
        model: LocalModel,
        previousSummary: String?,
        messages: [Message]
    ) async throws -> String {
        var parts: [String] = []
        if let previousSummary, !previousSummary.isEmpty {
            parts.append(
                "<previous_summary>\(previousSummary)</previous_summary>"
            )
        }

        parts.append(PromptBuilder.compressionText(messages))

        let summary = try await LMService.shared.generateAuxiliary(
            model: model,
            messages: PromptBuilder.summarize(
                conversation: parts.joined(separator: "\n")
            )
        )
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskExecutionError.emptyCheckpoint
        }
        return summary
    }

    private func buildPrompt(
        chat: Chat?, ticket: Ticket? = nil
    ) -> [MLXLMCommon.Chat.Message] {
        if let ticket = ticket ?? chat?.activeTicket, let session = ticket.session {
            return LMService.shared.protocolMessages([
                PromptBuilder.system(project: chat?.project, summary: session.checkpoint, ticket: ticket)
            ] + session.context)
        }
        var history: [Message] = []
        var messages = [PromptBuilder.system(project: chat?.project, summary: chat?.summary)]
        if let chat {
            let messages = chat.conversation
            history = Array(messages.suffix(from: summaryStartIndex(of: chat, in: messages)))
        }
        messages.append(contentsOf: history)
        return LMService.shared.protocolMessages(messages)
    }

    /// Where the messages the summary does not cover begin in `conversation`.
    private func summaryStartIndex(of chat: Chat, in conversation: [Message]) -> Int {
        chat.summaryBoundaryID
            .flatMap { id in conversation.firstIndex { $0.id == id } } ?? 0
    }

    private func availableTools(for chat: Chat?) -> [ToolSpec] {
        ToolDefinition.allToolSchema(for: chat)
    }
}

private enum TaskExecutionError: LocalizedError {
    case alreadyRunning, emptyCheckpoint

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: String(localized: "This task is already running.")
        case .emptyCheckpoint: String(localized: "The model returned an empty context checkpoint.")
        }
    }
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
