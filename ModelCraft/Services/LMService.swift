//
//  LMService.swift
//  ModelCraft
//
//  Created by Hongshen on 23/2/26.
//

import Foundation
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
            container = try await loadModelContainer(configuration: .init(directory: hub.localRepoLocation(.init(id: model.id))))
        } catch {
            // Download model from remote repo
            container = try await loadModelContainer(hub: hub, configuration: .init(id: model.id))
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
        return output
    }
    
    func generate(
        model: LocalModel,
        messages: [Message],
        tools: [ToolSpec] = [],
        maxTokens: Int? = nil
    ) async throws -> String {
        return try await generate(
            model: model,
            messages: messages.compactMap { toMessage($0) },
            tools: tools,
            maxTokens: maxTokens)
    }
    
}

extension LMService {
    
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
