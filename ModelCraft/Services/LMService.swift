//
//  LMService.swift
//  ModelCraft
//
//  Created by Hongshen on 23/2/26.
//

import UniformTypeIdentifiers

import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Hub
import Tokenizers

struct ContextWindowUsage: Equatable, Sendable {
    let usedTokens: Int
    let totalTokens: Int

    var fraction: Double {
        guard totalTokens > 0 else { return 0 }
        return min(Double(usedTokens) / Double(totalTokens), 1)
    }
}

/// A service class that manages machine learning models for text and vision-language tasks.
/// This class handles model loading, caching, and text generation using various LLM and VLM models.
final class LMService {
    
    static let shared = LMService()
    
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

    func contextUsage(
        model: LocalModel,
        messages: [MLXLMCommon.Chat.Message],
        tools: [ToolSpec] = []
    ) async throws -> ContextWindowUsage {
        let lease = try await InferenceRuntimeCoordinator.shared.acquire()

        do {
            let modelContainer = try await load(model: model)
            let usedTokens = try await modelContainer.perform { context in
                let input = try await context.processor.prepare(
                    input: UserInput(chat: messages, tools: tools))
                return input.text.tokens.size
            }
            await lease.release()
            return ContextWindowUsage(
                usedTokens: usedTokens,
                totalTokens: model.contextWindow)
        } catch {
            await lease.release()
            throw error
        }
    }
    
    /// Generates text based on the provided messages using the specified model.
    /// - Parameters:
    ///   - model: The language model to use for generation
    ///   - messages: Array of chat messages including user, assistant, and system messages
    ///   - tools: Array of available tools
    /// - Returns: An AsyncStream of generated text tokens
    /// - Throws: Errors that might occur during generation
    func generate(
        model: LocalModel,
        messages: [MLXLMCommon.Chat.Message],
        tools: [ToolSpec] = [],
        maxTokens: Int? = nil
    ) async throws -> AsyncStream<Generation> {
        let lease = try await InferenceRuntimeCoordinator.shared.acquire()

        do {
            let modelContainer = try await load(model: model)
            let userInput = UserInput(
                chat: messages,
                processing: .init(resize: .init(width: 1024, height: 1024)),
                tools: tools,
            )

            let inner = try await modelContainer.perform { (context: ModelContext) in
                let fullInput = try await context.processor.prepare(input: userInput)
                let availableTokens = max(
                    model.contextWindow - fullInput.text.tokens.size,
                    0)
                let parameters = GenerateParameters(
                    maxTokens: min(maxTokens ?? availableTokens, availableTokens),
                    temperature: 0.7,
                    prefillStepSize: 256)
                let modelIdentity = ObjectIdentifier(context.model)
                var generationInput = fullInput
                var generationCache: [KVCache]?
                var generationCacheKey: String?

                let canUsePrefixCache = fullInput.image == nil && fullInput.video == nil && messages.count > 1
                if canUsePrefixCache {
                    do {
                        let history = Array(messages.dropLast())
                        let historyInput = try await context.processor.prepare(
                            input: UserInput(chat: history, tools: tools))
                        if historyInput.image == nil && historyInput.video == nil {
                            let fullTokens = fullInput.text.tokens.flattened().asArray(Int.self)
                            let historyTokens = historyInput.text.tokens.flattened().asArray(Int.self)
                            let sharedCount = min(fullTokens.count, historyTokens.count)
                            var prefixCount = 0
                            while prefixCount < sharedCount,
                                  fullTokens[prefixCount] == historyTokens[prefixCount] {
                                prefixCount += 1
                            }
                            if prefixCount > 0, prefixCount < fullTokens.count {
                                let prefixTokens = Array(fullTokens.prefix(prefixCount))
                                let key = PromptCacheKey.make(
                                    modelID: model.id,
                                    modelIdentity: modelIdentity,
                                    prefixTokens: prefixTokens,
                                    tools: tools)

                                if let cached = KVCacheManager.shared.cachedCopy(for: key) {
                                    if !cached.isEmpty,
                                       cached.allSatisfy({ $0.offset == prefixCount }) {
                                        generationInput = LMInput(
                                            text: .init(tokens: MLXArray(
                                                Array(fullTokens[prefixCount...]))),
                                            image: nil,
                                            video: nil)
                                        generationCache = cached
                                        generationCacheKey = key
                                    } else {
                                        KVCacheManager.shared.clear(for: key)
                                    }
                                } else {
                                    let built = context.model.newCache(parameters: parameters)
                                    let prefixInput = LMInput(
                                        text: .init(
                                            tokens: MLXArray(prefixTokens)),
                                        image: nil,
                                        video: nil)
                                    _ = try TokenIterator(
                                        input: prefixInput,
                                        model: context.model,
                                        cache: built,
                                        parameters: parameters)
                                    eval(built)
                                    KVCacheManager.shared.save(cache: built, for: key)
                                    generationInput = LMInput(
                                        text: .init(tokens: MLXArray(
                                            Array(fullTokens[prefixCount...]))),
                                        image: nil,
                                        video: nil)
                                    generationCache = built.map { $0.copy() }
                                    generationCacheKey = key
                                }
                            }
                        }
                    } catch {
                        generationInput = fullInput
                        generationCache = nil
                        generationCacheKey = nil
                    }
                }

                do {
                    let iterator = try TokenIterator(
                        input: generationInput,
                        model: context.model,
                        cache: generationCache,
                        parameters: parameters)
                    return MLXLMCommon.generateTask(
                        promptTokenCount: fullInput.text.tokens.size,
                        modelConfiguration: context.configuration,
                        tokenizer: context.tokenizer,
                        iterator: iterator)
                } catch where generationCache != nil {
                    if let generationCacheKey {
                        KVCacheManager.shared.clear(for: generationCacheKey)
                    }
                    let iterator = try TokenIterator(
                        input: fullInput,
                        model: context.model,
                        cache: nil,
                        parameters: parameters)
                    return MLXLMCommon.generateTask(
                        promptTokenCount: fullInput.text.tokens.size,
                        modelConfiguration: context.configuration,
                        tokenizer: context.tokenizer,
                        iterator: iterator)
                }
            }

            return AsyncStream { continuation in
                let task = Task {
                    for await item in inner.0 {
                        if Task.isCancelled { break }
                        continuation.yield(item)
                    }

                    // `AsyncStream` can finish before the producer task has
                    // released its iterator/cache. Cancel on early stop and
                    // wait for the producer before making the global lease
                    // available to another model. Finishing the outer stream
                    // last also prevents an immediate regenerate from
                    // observing completion while the lease is still held.
                    inner.1.cancel()
                    await inner.1.value
                    await lease.release()
                    continuation.finish()
                }
                continuation.onTermination = { _ in
                    task.cancel()
                    inner.1.cancel()
                }
            }
        } catch {
            await lease.release()
            throw error
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
        for await segment in try await generate(
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
