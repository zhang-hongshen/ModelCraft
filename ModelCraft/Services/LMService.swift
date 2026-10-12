//
//  LMService.swift
//  ModelCraft
//
//  Created by Hongshen on 23/2/26.
//

import CoreImage
import Foundation
import FoundationModels
import UniformTypeIdentifiers

import MLX
import MLXLMCommon
import Hub
import Tokenizers

/// A service class that manages machine learning models for text and vision-language tasks.
/// This class handles model loading, caching, and text generation using various LLM and VLM models.
final class LMService {
    
    static let shared = LMService()

    private let deepSeekFlashEvaluator = DeepSeekFlashEvaluator()
    
    /// Cache to store loaded model containers to avoid reloading.
    private let modelCache: NSCache<NSString, ModelContainer> = {
        let cache = NSCache<NSString, ModelContainer>()
        cache.countLimit = 5
        return cache
    }()
    
    /// Loads a model from the hub or retrieves it from cache.
    /// - Parameter modelID: The model configuration to load
    /// - Returns: A ModelContainer instance containing the loaded model
    /// - Throws: Errors that might occur during model loading
    private func load(hub: HubApi = .default, model: LocalModel) async throws -> ModelContainer {

        // Return cached model if available to avoid reloading
        if let container = modelCache.object(forKey: model.id as NSString) {
            return container
        }
        let container: ModelContainer
        do {
            // Load model from on-disk file
            container = try await loadModelContainer(
                from: hub.localRepoLocation(.init(id: model.id)),
                using: TransformersTokenizerLoader())
        } catch {
            // Download model from remote repo
            container = try await loadModelContainer(
                from: hub,
                using: TransformersTokenizerLoader(),
                configuration: .init(id: model.id))
        }
        
        // Cache the loaded model for future use
        modelCache.setObject(container, forKey: model.id as NSString)
        return container
    }

    private func isDeepSeekFlash(_ model: LocalModel) -> Bool {
        model.id == DeepSeekFlashEvaluator.repositoryID
    }

    func tokenCount(
        model: LocalModel,
        messages: [MLXLMCommon.Chat.Message],
        tools: [ToolSpec] = []
    ) async throws -> Int {
        if isDeepSeekFlash(model) {
            return try await deepSeekFlashEvaluator.tokenCount(
                messages: messages,
                tools: tools)
        }

        let modelContainer = try await load(model: model)
        return try await modelContainer.perform { context in
            let input = try await context.processor.prepare(
                input: UserInput(chat: messages, tools: tools))
            return input.text.tokens.size
        }
    }

    /// Generates text based on the provided messages using the specified model.
    /// - Parameters:
    ///   - model: The language model to use for generation
    ///   - messages: Array of chat messages including user, assistant, and system messages
    ///   - tools: Array of available tools
    /// - Returns: An asynchronous stream of generated text tokens
    /// - Throws: Errors that might occur during generation
    func generate(
        model: LocalModel,
        messages: [MLXLMCommon.Chat.Message],
        tools: [ToolSpec] = [],
        maxTokens: Int? = nil
    ) async throws -> AsyncThrowingStream<Generation, Error> {
        if isDeepSeekFlash(model) {
            return try await deepSeekFlashEvaluator.generate(
                messages: messages,
                tools: tools,
                maximumSequenceLength: min(model.contextWindow, 65_536),
                maximumNewTokens: maxTokens,
                temperature: 0.7)
        }

        let modelContainer = try await load(model: model)
        let userInput = UserInput(
            chat: messages,
            processing: .init(resize: .init(width: 1024, height: 1024)),
            tools: tools,
        )

        let stream = try await modelContainer.perform { (context: ModelContext) in
            let lmInput = try await context.processor.prepare(input: userInput)
            let parameters = GenerateParameters(temperature: 0.7)
            return try MLXLMCommon.generate(input: lmInput, parameters: parameters, context: context)
        }

        return AsyncThrowingStream<Generation, Error> { continuation in
            let task = Task {
                for await value in stream {
                    if Task.isCancelled { break }
                    continuation.yield(value)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Generates text based on the provided messages using the specified model.
    /// - Parameters:
    ///   - model: The language model to use for generation
    ///   - messages: Array of chat messages including user, assistant, and system messages
    ///   - tools: Array of available tools
    /// - Returns: A String of generated text tokens
    /// - Throws: Errors that might occur during generation
    func generate(
        model: LocalModel,
        messages: [MLXLMCommon.Chat.Message],
        tools: [ToolSpec] = [],
        maxTokens: Int? = nil
    ) async throws -> String {
        var output = ""
        for try await segment in try await generate(
            model: model,
            messages: messages,
            tools: tools,
            maxTokens: maxTokens) {
            try Task.checkCancellation()
            if let chunk = segment.chunk {
                output.append(chunk)
            }
        }
        try Task.checkCancellation()
        // Callers use the answer only, so leading model reasoning is dropped.
        let answer = output.drop { $0.isWhitespace }
        if answer.hasPrefix("<think>"), let end = answer.range(of: "</think>") {
            return answer[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return output
    }
    
    /// Generates a short auxiliary text, such as a chat title or compaction summary.
    /// Apple's on-device model answers when the system offers it; otherwise, or when it
    /// rejects the prompt (context size, language, guardrails), `model` generates it.
    func generateAuxiliary(
        model: LocalModel,
        messages: [Message]
    ) async throws -> String {
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            do {
                return try await generateOnDevice(messages: messages)
            } catch {
                try Task.checkCancellation()
            }
        }
        return try await generate(
            model: model,
            messages: protocolMessages(messages))
    }

    @available(macOS 26.0, *)
    private func generateOnDevice(messages: [Message]) async throws -> String {
        let instructions = messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        let prompt = messages
            .filter { $0.role != .system }
            .map(\.content)
            .joined(separator: "\n\n")
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            options: GenerationOptions(temperature: 0.7))
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
}

extension LMService {

    func protocolMessages(_ messages: [Message]) -> [MLXLMCommon.Chat.Message] {
        var protocolMessages: [MLXLMCommon.Chat.Message] = []
        for message in messages {
            append(message, to: &protocolMessages)
        }
        return protocolMessages
    }

    /// Appends the protocol form of a persisted message. A tool message is preceded by the
    /// assistant tool call that produced it, attached to the preceding assistant text when
    /// there is one, so chat templates can pair the result with its call. Images and videos
    /// in the tool result are attached to the tool message so the model can see them.
    func append(_ message: Message, to messages: inout [MLXLMCommon.Chat.Message]) {
        guard message.role == .tool, let toolCall = message.toolCall else {
            messages.append(toMessage(message))
            return
        }
        if let last = messages.last, last.role == .assistant, last.tool == nil {
            messages[messages.count - 1].tool = .calls([toolCall])
        } else {
            messages.append(.assistant("", toolCalls: [toolCall]))
        }
        var toolMessage = MLXLMCommon.Chat.Message.tool(
            message.content, id: toolCall.id, name: toolCall.function.name)
        for block in message.toolCallResult?.content ?? [] {
            switch block {
            case .image(let image):
                if let data = Data(base64Encoded: image.data),
                   let ciImage = CIImage(data: data) {
                    toolMessage.images.append(.ciImage(ciImage))
                }
            case .resourceLink(let link):
                guard let type = link.mimeType.flatMap({ UTType(mimeType: $0) }) else { continue }
                if type.conforms(to: .image) {
                    toolMessage.images.append(.url(link.url))
                } else if type.conforms(to: .movie) {
                    toolMessage.videos.append(.url(link.url))
                }
            default:
                break
            }
        }
        messages.append(toolMessage)
    }

    func toMessage(_ message: Message) -> MLXLMCommon.Chat.Message {
        let role: MLXLMCommon.Chat.Message.Role =
            switch message.role {
            case .assistant: .assistant
            case .user: .user
            case .system: .system
            case .tool: .tool
            }

        // Process any attached media for VLM models
        
        var images: [UserInput.Image] = []
        var videos: [UserInput.Video] = []
        for url in message.files {
            if let type = UTType(filenameExtension: url.pathExtension),
                type.conforms(to: .image) {
                images.append(.url(url))
            } else if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .movie) {
                videos.append(.url(url))
            }
        }

        return MLXLMCommon.Chat.Message(role: role, content: message.content, images: images, videos: videos)
    }
}

/// Loads model tokenizers with swift-transformers for MLX model containers.
private struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {

    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TransformersTokenizer(try await AutoTokenizer.from(modelFolder: directory))
    }
}

/// Presents a swift-transformers tokenizer as an MLXLMCommon tokenizer.
struct TransformersTokenizer: MLXLMCommon.Tokenizer {

    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
