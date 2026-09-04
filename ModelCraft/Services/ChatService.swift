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
class ChatService {
    
    private let chatModelActor = ChatModelActor(modelContainer: ModelContainer.shared)
    
    let decisionCoordinator: DecisionCoordinator
    private let executor: AgentExecutor
    
    private var currentTask: Task<Void, any Error>? = nil
    private var metadataTask: Task<Void, Never>? = nil
    private var contextUsageTask: Task<Void, Never>? = nil
    private var currentRequestID: UUID?

    private(set) var contextUsage: ContextWindowUsage?
    private(set) var isPreparingResponse = false
    private(set) var isCompacting = false

    private static let compressionTrigger = 0.75
    private static let summaryInputLimit = 0.70

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
        isPreparingResponse = false
        task.cancel()
        _ = try? await task.value
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
        // A title/summary is optional background work. Never let an older
        // metadata request sit ahead of a new user generation in the global
        // inference queue (especially when regenerating immediately).
        metadataTask?.cancel()
        metadataTask = nil
        contextUsageTask?.cancel()
        contextUsageTask = nil
        await cancelCurrentGeneration()

        let requestID = UUID()
        currentRequestID = requestID

        ModelContainer.shared.mainContext.persist(message)

        let generationTask = Task {
            do {
                try await compactContextIfNeeded(
                    model: model,
                    chat: chat,
                    question: message)
                isPreparingResponse = false
                try await executor.run(
                    model: model,
                    projectID: chat.project?.persistentModelID,
                    chat: chat,
                    messages: promptMessages(
                        chat: chat,
                        question: message),
                    generationInfoHandler: { [weak self] info in
                        self?.contextUsage = ContextWindowUsage(
                            usedTokens: info.promptTokenCount + info.generationTokenCount,
                            totalTokens: model.contextWindow)
                    })
            } catch {
                isPreparingResponse = false
                throw error
            }
        }

        isPreparingResponse = true
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
        guard currentTask == nil,
              !isPreparingResponse,
              !chat.isGenerating else {
            return
        }

        metadataTask?.cancel()
        metadataTask = nil
        contextUsageTask?.cancel()
        contextUsageTask = nil

        let messages = chat.sortedMessages
        let startIndex = min(chat.lastSummaryIndex, messages.count)
        let messagesToSummarize = Array(messages.suffix(from: startIndex))
        guard !messagesToSummarize.isEmpty else { return }

        isCompacting = true
        defer { isCompacting = false }

        chat.summary = try await summarize(
            model: model,
            previousSummary: chat.summary,
            messages: messagesToSummarize)
        chat.lastSummaryIndex = messages.count
        try ModelContainer.shared.mainContext.save()
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
        contextUsageTask?.cancel()
        contextUsageTask = nil
        currentRequestID = nil
        isPreparingResponse = false
        if let currentMessage = chat.currentGeneratingAssistantMessage {
            currentMessage.status = .generated
        }
    }

    func scheduleContextUsage(
        model: LocalModel?,
        chat: Chat?
    ) {
        contextUsageTask?.cancel()
        guard let model else {
            contextUsage = nil
            return
        }
        let hasConversationContext = chat?.messages.contains { message in
            switch message.role {
            case .assistant:
                message.status == .generated
            case .tool:
                message.status != .generating
            case .user, .system:
                false
            }
        } == true || chat?.summary?.isEmpty == false
        guard hasConversationContext else {
            contextUsage = nil
            return
        }

        contextUsageTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard chat?.isGenerating != true, !isPreparingResponse else { return }
                try await refreshContextUsage(
                    model: model,
                    chat: chat)
            } catch {
                // Context usage is informational and must not affect chat.
            }
        }
    }

    private func refreshContextUsage(
        model: LocalModel,
        chat: Chat?
    ) async throws {
        let draft = Message(role: .user)
        let usage = try await LMService.shared.contextUsage(
            model: model,
            messages: promptMessages(
                chat: chat,
                question: draft),
            tools: availableTools(for: chat))
        try Task.checkCancellation()
        contextUsage = usage
    }

    private func compactContextIfNeeded(
        model: LocalModel,
        chat: Chat,
        question: Message
    ) async throws {
        var usage = try await measureContextUsage(
            model: model,
            chat: chat,
            question: question)

        guard usage.fraction >= Self.compressionTrigger else { return }

        while usage.fraction >= Self.compressionTrigger {
            let messages = chat.sortedMessages
            let startIndex = min(chat.lastSummaryIndex, messages.count)
            let boundaries = messages.indices.filter {
                $0 > startIndex && messages[$0].role == .user
            }
            guard !boundaries.isEmpty else {
                try ensureUsageFitsSelectedModel(usage)
                return
            }
            let compressionEnd = boundaries[boundaries.count - 1]

            let messagesToSummarize = Array(messages[startIndex..<compressionEnd])
            guard !messagesToSummarize.isEmpty,
                  !messagesToSummarize.contains(where: { $0.status == .generating }) else {
                return
            }

            let summary = try await summarize(
                model: model,
                previousSummary: chat.summary,
                messages: messagesToSummarize)
            try Task.checkCancellation()

            chat.summary = summary
            chat.lastSummaryIndex = compressionEnd
            try ModelContainer.shared.mainContext.save()

            usage = try await measureContextUsage(
                model: model,
                chat: chat,
                question: question)
        }
    }

    private func summarize(
        model: LocalModel,
        previousSummary: String?,
        messages: [Message]
    ) async throws -> String {
        var summary = previousSummary
        var batch: [Message] = []

        for message in messages {
            let candidate = batch + [message]
            if try await summaryPromptFits(
                model: model,
                previousSummary: summary,
                messages: candidate) {
                batch = candidate
                continue
            }

            if !batch.isEmpty {
                summary = try await generateSummary(
                    model: model,
                    previousSummary: summary,
                    messages: batch)
                batch.removeAll(keepingCapacity: true)
            }

            var singleMessageFits = try await summaryPromptFits(
                model: model,
                previousSummary: summary,
                messages: [message])
            if !singleMessageFits,
               let existingSummary = summary,
               !existingSummary.isEmpty,
               try await summaryPromptFits(
                    model: model,
                    previousSummary: existingSummary,
                    messages: []) {
                summary = try await generateSummary(
                    model: model,
                    previousSummary: existingSummary,
                    messages: [])
                singleMessageFits = try await summaryPromptFits(
                    model: model,
                    previousSummary: summary,
                    messages: [message])
            }

            guard singleMessageFits else {
                throw NSError(
                    domain: "ContextCompression",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "A single conversation item exceeds the selected model's context window."
                    ])
            }
            batch.append(message)
        }

        if !batch.isEmpty {
            summary = try await generateSummary(
                model: model,
                previousSummary: summary,
                messages: batch)
        }

        return summary ?? ""
    }

    private func summaryPromptFits(
        model: LocalModel,
        previousSummary: String?,
        messages: [Message]
    ) async throws -> Bool {
        let prompt = PromptBuilder.summarize(
            previousSummary: previousSummary,
            messages: messages)
            .map { LMService.shared.toMessage($0) }
        let usage = try await LMService.shared.contextUsage(
            model: model,
            messages: prompt)
        return usage.usedTokens <= Int(
            Double(model.contextWindow) * Self.summaryInputLimit)
    }

    private func generateSummary(
        model: LocalModel,
        previousSummary: String?,
        messages: [Message]
    ) async throws -> String {
        try await LMService.shared.generate(
            model: model,
            messages: PromptBuilder.summarize(
                previousSummary: previousSummary,
                messages: messages))
    }

    private func ensureUsageFitsSelectedModel(
        _ usage: ContextWindowUsage
    ) throws {
        guard usage.usedTokens > usage.totalTokens else { return }
        throw NSError(
            domain: "ContextCompression",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The latest conversation turn exceeds the selected model's context window."
            ])
    }

    private func measureContextUsage(
        model: LocalModel,
        chat: Chat,
        question: Message
    ) async throws -> ContextWindowUsage {
        try await LMService.shared.contextUsage(
            model: model,
            messages: promptMessages(chat: chat, question: question),
            tools: availableTools(for: chat))
    }

    private func promptMessages(
        chat: Chat?,
        question: Message,
        historyStart: Int? = nil
    ) -> [MLXLMCommon.Chat.Message] {
        var history: [Message] = []
        if let chat {
            let messages = chat.sortedMessages
            let startIndex = min(historyStart ?? chat.lastSummaryIndex, messages.count)
            history = Array(messages.suffix(from: startIndex))
        }
        return ([PromptBuilder.multiStepAgentSystemPrompt]
            + history
            + [PromptBuilder.answerQuestion(
                question: question.content,
                summary: chat?.summary)])
            .map { LMService.shared.toMessage($0) }
    }

    private func availableTools(for chat: Chat?) -> [ToolSpec] {
        var tools = ToolDefinition.allToolSchema
        if let projectID = chat?.project?.persistentModelID {
            tools.append(
                SearchTool.searchRelevantDocuments(projectID: projectID).schema)
        }
        return tools
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
