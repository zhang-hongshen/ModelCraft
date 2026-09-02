//
//  ChatService.swift
//  ModelCraft
//
//  Created by Hongshen on 11/1/26.
//

import SwiftUI
import SwiftData


@MainActor
@Observable
class ChatService {
    
    private let chatModelActor = ChatModelActor(modelContainer: ModelContainer.shared)
    
    let decisionCoordinator: DecisionCoordinator
    private let executor: AgentExecutor
    
    private var currentTask: Task<Void, any Error>? = nil
    private var metadataTask: Task<Void, Never>? = nil
    private var currentRequestID: UUID?

    init() {
        let decisionCoordinator = DecisionCoordinator()
        self.decisionCoordinator = decisionCoordinator
        self.executor = AgentExecutor { model, messages, tools in
            try await LMService.shared.generate(
                model: model,
                messages: messages,
                tools: tools)
        } toolDispatcher: { toolCall in
            try await ToolExecutor.shared.dispath(toolCall)
        } decisionProvider: { request in
            try await decisionCoordinator.request(request)
        }
    }

    private func cancelCurrentGeneration() async {
        guard let task = currentTask else { return }
        currentTask = nil
        currentRequestID = nil
        task.cancel()
        _ = try? await task.value
    }
    
    func deleteChat(_ chat: Chat) {
        ModelContainer.shared.mainContext.delete(chat)
    }
    
    func createChat() -> Chat {
        let chat = Chat()
        ModelContainer.shared.mainContext.persist(chat)
        return chat
    }
    
    func sendMessage(
        model: LocalModel,
        chat: Chat,
        message: Message,
    ) async throws {
        // A title/summary is optional background work. Never let an older
        // metadata request sit ahead of a new user generation in the global
        // inference queue (especially when regenerating immediately).
        metadataTask?.cancel()
        metadataTask = nil
        await cancelCurrentGeneration()

        let requestID = UUID()
        currentRequestID = requestID

        ModelContainer.shared.mainContext.persist(message)

        let generationTask = Task {
            let messages = [PromptBuilder.multiStepAgentSystemPrompt]
            + Array(chat.sortedMessages.suffix(from: chat.lastSummaryIndex))
            + [PromptBuilder.answerQuestion(question: message.content, summary: chat.summary)]
            try await executor.run(model: model, projectID: chat.project?.persistentModelID, chat: chat, messages: messages.compactMap { LMService.shared.toMessage($0) })
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

        guard currentRequestID == requestID else { return }
        currentTask = nil

        // Start optional metadata only after the answer has released its LLM
        // lease. The next sendMessage() cancels this task before queueing new
        // inference, so it cannot make regeneration wait behind title work.
        metadataTask = Task(priority: .background) { @MainActor in
            do {
                guard self.currentRequestID == requestID else { return }
                try Task.checkCancellation()
                try await self.generateTitleIfNeeded(model: model, chatID: chat.id)
                try Task.checkCancellation()
                guard self.currentRequestID == requestID else { return }
                try await self.summarizeChatIfNeeded(model: model, chatID: chat.id)
            } catch is CancellationError {
                // Expected when a new request supersedes background metadata.
            } catch {
                // Metadata is best effort and must not affect the chat turn.
            }
        }
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
        try await sendMessage(
            model: model,
            chat: chat,
            message: message)
    }
    
    private func summarizeChatIfNeeded (model: LocalModel, chatID: PersistentIdentifier) async throws {
        try await chatModelActor.updateSummary(chatID: chatID) { previousSummary, messages in
                let prompt = PromptBuilder.summarize(previousSummary: previousSummary, messages: messages)
            return try await LMService.shared.generate(
                model: model,
                messages: prompt)
        }
    }

    private func generateTitleIfNeeded (model: LocalModel, chatID: PersistentIdentifier) async throws {
        try await chatModelActor.generateTitle(chatID: chatID) { messages in
            let prompt = PromptBuilder.generateTitle(messages: messages)
            return try await LMService.shared.generate(
                model: model,
                messages: prompt)
        }
    }
    
    func stopGenerating(chat: Chat) {
        currentTask?.cancel()
        decisionCoordinator.cancel()
        metadataTask?.cancel()
        metadataTask = nil
        currentRequestID = nil
        if let currentMessage = chat.currentGeneratingAssistantMessage {
            currentMessage.status = .generated
        }
    }
}

@MainActor
@Observable
final class DecisionCoordinator {

    struct PendingDecision: Identifiable, Sendable {
        let id = UUID()
        let request: RequestDecisionInput
    }

    private(set) var pendingDecision: PendingDecision?
    @ObservationIgnored
    private var continuation: CheckedContinuation<RequestDecisionOutput, any Error>?

    func request(_ request: RequestDecisionInput) async throws -> RequestDecisionOutput {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingDecision = PendingDecision(request: request)
                self.continuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    func submit(_ answers: [DecisionAnswer]) {
        let continuation = self.continuation
        self.continuation = nil
        pendingDecision = nil
        continuation?.resume(returning: RequestDecisionOutput(answers: answers))
    }

    func cancel() {
        let continuation = self.continuation
        self.continuation = nil
        pendingDecision = nil
        continuation?.resume(throwing: CancellationError())
    }
}
