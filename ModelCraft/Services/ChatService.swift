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

    private static let compressionTrigger = 0.75

    init() {
        let interactionCoordinator = UserInteractionCoordinator()
        self.interactionCoordinator = interactionCoordinator
        self.executor = AgentExecutor(interactionCoordinator: interactionCoordinator)
    }

    private func cancelCurrentGeneration() async {
        guard let task = currentTask else { return }
        let requestID = currentRequestID
        task.cancel()
        _ = try? await task.value
        guard currentRequestID == requestID else { return }
        currentTask = nil
        currentRequestID = nil
    }
    
    func deleteChat(_ chat: Chat) {
        ModelContainer.shared.mainContext.delete(chat)
    }
    
    func createChat(project: Project? = nil) -> Chat {
        let chat = Chat(project: project)
        ModelContainer.shared.mainContext.persist(chat)
        return chat
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

        ModelContainer.shared.mainContext.persist(message)
        let generationTask = Task {
            try await compactContextIfNeeded(
                model: model,
                chat: chat)
            try await executor.run(
                model: model,
                chat: chat,
                messages: buildPrompt(chat: chat))
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
    }
    
    func resendMessage(
        model: LocalModel,
        chat: Chat,
        message: Message
    ) async throws {
        await cancelCurrentGeneration()
        guard let index = chat.sortedMessages.firstIndex (where: { $0.id == message.id }) else { return }
        let messagesToDelete = Array(chat.sortedMessages[(index+1)...])
        chat.truncateMessages(messages: messagesToDelete)
        ModelContainer.shared.mainContext.delete(messagesToDelete)
        if index < chat.lastSummaryIndex {
            chat.lastSummaryIndex = 0
            chat.summary = nil
        }
        try await sendMessage(
            model: model,
            chat: chat,
            message: message)
    }

    func compactContext(
        model: LocalModel,
        chat: Chat
    ) async throws {
        let messages = chat.sortedMessages
        let startIndex = min(chat.lastSummaryIndex, messages.count)

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
        chat.lastSummaryIndex = endIndex
        try ModelContainer.shared.mainContext.save()
        
        let tokenCount = try await LMService.shared.tokenCount(
            model: model,
            messages: buildPrompt(
                chat: chat),
            tools: availableTools(for: chat))
    }

    private func compactContextIfNeeded(
        model: LocalModel,
        chat: Chat
    ) async throws {
        let tokenCount = try await LMService.shared.tokenCount(
            model: model,
            messages: buildPrompt(chat: chat),
            tools: availableTools(for: chat))

        guard tokenCount >= Int(
            Self.compressionTrigger * Double(model.contextWindow)
        ) else {
            return
        }
        try await compactContext(
            model: model,
            chat: chat
        )
    }
    
    private func generateTitleIfNeeded (model: LocalModel, chat: Chat) async throws {
        if chat.title != nil {
            return
        }
        let prompt = PromptBuilder.generateTitle(messages: chat.messages)
        chat.title = try await LMService.shared.generate(
            model: model,
            messages: prompt)
    }
    
    func stopGenerating(chat: Chat) async {
        interactionCoordinator.cancel()
        metadataTask?.cancel()
        metadataTask = nil
        await cancelCurrentGeneration()
        if let currentMessage = chat.currentGeneratingAssistantMessage {
            currentMessage.status = .generated
        }
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

        return try await LMService.shared.generate(
            model: model,
            messages: PromptBuilder.summarize(
                conversation: parts.joined(separator: "\n")
            )
        )
    }

    private func buildPrompt(
        chat: Chat?
    ) -> [MLXLMCommon.Chat.Message] {
        var history: [Message] = []
        var messages = [PromptBuilder.system]
        if let chat {
            if let project = chat.project {
                messages.append(PromptBuilder.environment(project: project))
            }
            if let summary = chat.summary {
                messages.append(PromptBuilder.summary(summary: summary))
            }
            let messages = chat.sortedMessages
            let startIndex = min(chat.lastSummaryIndex, messages.count)
            history = Array(messages.suffix(from: startIndex))
        }
        messages.append(contentsOf: history)
        return messages.map { LMService.shared.toMessage($0) }
    }

    private func availableTools(for chat: Chat?) -> [ToolSpec] {
        var tools = ToolDefinition.allToolSchema
        if let projectID = chat?.project?.persistentModelID {
            tools.append(
                SearchTool.searchProject(projectID: projectID).schema)
        }
        return tools
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
    private var approvalContinuation: CheckedContinuation<Bool, any Error>?

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

    func requestApproval(_ request: ToolApprovalRequest) async throws -> Bool {
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

    func resolveApproval(_ isApproved: Bool) {
        let continuation = approvalContinuation
        approvalContinuation = nil
        pendingInteraction = nil
        continuation?.resume(returning: isApproved)
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
