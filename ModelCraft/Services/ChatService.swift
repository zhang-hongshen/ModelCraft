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
    
    private let chatModelActor = ChatModelActor(modelContainer: ModelContainer.shared)
    
    let interactionCoordinator: UserInteractionCoordinator
    private let executor: AgentExecutor
    
    private var currentTask: Task<Void, any Error>? = nil
    private var metadataTask: Task<Void, Never>? = nil
    private var currentRequestID: UUID?

    private(set) var isCompacting = false

    private static let compressionTrigger = 0.75
    private static let summaryInputLimit = 0.70
    private static let summaryOutputLimit = 0.20
    private static let maximumSummaryOutputTokens = 4_096

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
            do {
                try await compactContextIfNeeded(
                    model: model,
                    chat: chat,
                    question: message)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                ModelContainer.shared.mainContext.persist(Message(
                    role: .assistant,
                    chat: chat,
                    content: error.localizedDescription,
                    status: .failed))
                throw error
            }
            try await executor.run(
                model: model,
                chat: chat,
                messages: promptMessages(
                    chat: chat,
                    question: message))
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
              !chat.isGenerating else {
            return
        }

        metadataTask?.cancel()
        metadataTask = nil

        let messages = chat.sortedMessages
        let startIndex = min(chat.lastSummaryIndex, messages.count)
        let messagesToSummarize = Array(messages.suffix(from: startIndex))
        guard !messagesToSummarize.isEmpty,
              !messagesToSummarize.contains(where: { $0.status == .generating }) else {
            return
        }

        isCompacting = true
        defer { isCompacting = false }

        let originalUsage = try await measureContextUsage(
            model: model,
            chat: chat,
            question: Message(role: .user))
        let summary = try await summarize(
            model: model,
            previousSummary: chat.summary,
            messages: messagesToSummarize)
        let compactedUsage = try await measureContextUsage(
            model: model,
            chat: chat,
            question: Message(role: .user),
            historyStart: messages.count,
            summary: summary)
        guard compactedUsage.usedTokens < originalUsage.usedTokens else { return }
        try ensureUsageFitsSelectedModel(compactedUsage)

        chat.summary = summary
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
    
    func stopGenerating(chat: Chat) async {
        interactionCoordinator.cancel()
        metadataTask?.cancel()
        metadataTask = nil
        await cancelCurrentGeneration()
        if let currentMessage = chat.currentGeneratingAssistantMessage {
            currentMessage.status = .generated
        }
    }

    private func compactContextIfNeeded(
        model: LocalModel,
        chat: Chat,
        question: Message
    ) async throws {
        let usage = try await measureContextUsage(
            model: model,
            chat: chat,
            question: question)

        guard usage.fraction >= Self.compressionTrigger else { return }

        let messages = chat.sortedMessages
        let startIndex = min(chat.lastSummaryIndex, messages.count)
        let boundaries = messages.indices.filter {
            $0 > startIndex && messages[$0].role == .user
        }
        guard let compressionEnd = boundaries.last else {
            try ensureUsageFitsSelectedModel(usage)
            return
        }

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
        let compactedUsage = try await measureContextUsage(
            model: model,
            chat: chat,
            question: question,
            historyStart: compressionEnd,
            summary: summary)
        guard compactedUsage.usedTokens < usage.usedTokens else { return }
        try ensureUsageFitsSelectedModel(compactedUsage)

        chat.summary = summary
        chat.lastSummaryIndex = compressionEnd
        try ModelContainer.shared.mainContext.save()
    }

    private func summarize(
        model: LocalModel,
        previousSummary: String?,
        messages: [Message]
    ) async throws -> String {
        var items: [String] = []
        if let previousSummary, !previousSummary.isEmpty {
            items.append(contentsOf: try await splitCompressionItem(
                "<previous_summary>\(previousSummary)</previous_summary>",
                model: model))
        }
        for message in messages {
            let record = PromptBuilder.compressionText([message])
            items.append(contentsOf: try await splitCompressionItem(
                record,
                model: model))
        }

        var summaries = try await summarizeItems(items, model: model)
        while summaries.count > 1 {
            let summaryItems = summaries.enumerated().map { index, summary in
                "<summary_part index=\"\(index + 1)\">\(summary)</summary_part>"
            }
            summaries = try await summarizeItems(summaryItems, model: model)
        }
        return summaries.first ?? previousSummary ?? ""
    }

    private func summarizeItems(
        _ items: [String],
        model: LocalModel
    ) async throws -> [String] {
        var summaries: [String] = []
        var startIndex = 0

        while startIndex < items.count {
            var lowerBound = startIndex + 1
            var upperBound = items.count
            var endIndex = startIndex

            while lowerBound <= upperBound {
                let middle = (lowerBound + upperBound) / 2
                let conversation = items[startIndex..<middle].joined(separator: "\n")
                if try await summaryPromptFits(model: model, conversation: conversation) {
                    endIndex = middle
                    lowerBound = middle + 1
                } else {
                    upperBound = middle - 1
                }
            }

            guard endIndex > startIndex else {
                throw NSError(
                    domain: "ContextCompression",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "A conversation item exceeds the selected model's context window."
                    ])
            }
            let conversation = items[startIndex..<endIndex].joined(separator: "\n")
            summaries.append(try await generateSummary(
                model: model,
                conversation: conversation))
            startIndex = endIndex
        }
        return summaries
    }

    private func splitCompressionItem(
        _ item: String,
        model: LocalModel
    ) async throws -> [String] {
        if try await summaryPromptFits(model: model, conversation: item) {
            return [item]
        }

        var fragments: [String] = []
        var remaining = item[...]
        while !remaining.isEmpty {
            var lowerBound = 1
            var upperBound = remaining.count
            var fragmentLength = 0

            while lowerBound <= upperBound {
                let middle = (lowerBound + upperBound) / 2
                let endIndex = remaining.index(
                    remaining.startIndex,
                    offsetBy: middle)
                let fragment = "<conversation_fragment>\(remaining[..<endIndex])</conversation_fragment>"
                if try await summaryPromptFits(model: model, conversation: fragment) {
                    fragmentLength = middle
                    lowerBound = middle + 1
                } else {
                    upperBound = middle - 1
                }
            }

            guard fragmentLength > 0 else {
                throw NSError(
                    domain: "ContextCompression",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The selected model's context window is too small to create a summary."
                    ])
            }
            let endIndex = remaining.index(
                remaining.startIndex,
                offsetBy: fragmentLength)
            fragments.append(
                "<conversation_fragment>\(remaining[..<endIndex])</conversation_fragment>")
            remaining = remaining[endIndex...]
        }
        return fragments
    }

    private func summaryPromptFits(
        model: LocalModel,
        conversation: String
    ) async throws -> Bool {
        let prompt = PromptBuilder.summarize(conversation: conversation)
            .map { LMService.shared.toMessage($0) }
        let usage = try await LMService.shared.contextUsage(
            model: model,
            messages: prompt)
        return usage.usedTokens <= Int(
            Double(model.contextWindow) * Self.summaryInputLimit)
    }

    private func generateSummary(
        model: LocalModel,
        conversation: String
    ) async throws -> String {
        try await LMService.shared.generate(
            model: model,
            messages: PromptBuilder.summarize(conversation: conversation),
            maxTokens: min(
                Self.maximumSummaryOutputTokens,
                Int(Double(model.contextWindow) * Self.summaryOutputLimit)))
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
        question: Message,
        historyStart: Int? = nil,
        summary: String? = nil
    ) async throws -> ContextWindowUsage {
        try await LMService.shared.contextUsage(
            model: model,
            messages: promptMessages(
                chat: chat,
                question: question,
                historyStart: historyStart,
                summary: summary),
            tools: availableTools(for: chat))
    }

    private func promptMessages(
        chat: Chat?,
        question: Message,
        historyStart: Int? = nil,
        summary: String? = nil
    ) -> [MLXLMCommon.Chat.Message] {
        var history: [Message] = []
        var messages = [PromptBuilder.agentSystemPrompt]
        if let chat {
            if let project = chat.project {
                messages.append(PromptBuilder.environment(project: project))
            }
            let messages = chat.sortedMessages
            let startIndex = min(historyStart ?? chat.lastSummaryIndex, messages.count)
            history = messages.suffix(from: startIndex).filter { $0.id != question.id }
        }
        messages.append(contentsOf: history + [PromptBuilder.answerQuestion(
            question: question.content,
            summary: summary ?? chat?.summary)])
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
