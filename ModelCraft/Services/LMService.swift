//
//  LMService.swift
//  ModelCraft
//
//  Created by Hongshen on 23/2/26.
//

import CoreImage
import UniformTypeIdentifiers

import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Hub
import Tokenizers

@inline(__always)
func makeSuffixTokens(fullTokens: MLXArray, prefixCount: Int) -> MLXArray {
    let suffix = fullTokens.flattened().asArray(Int32.self)
    return MLXArray(Array(suffix[prefixCount...])).reshaped(1, -1)
}

@inline(__always)
func prefixProbeToken(from prefixTokens: [Int]) -> Int? {
    prefixTokens.first
}

private enum PrefixCacheProbeError: Error {
    case emptyPrefix
}

struct ContextWindowUsage: Equatable, Sendable {
    let usedTokens: Int
    let totalTokens: Int

    var fraction: Double {
        guard totalTokens > 0 else { return 0 }
        return min(Double(usedTokens) / Double(totalTokens), 1)
    }
}

enum PromptCacheMetadata {
    static func matches(
        _ metadata: [String: String],
        modelID: String,
        prefixCount: Int,
        stateSignature: String,
        layoutSignature: String,
        modelRevision: String,
        tokenizerRevision: String,
        templateRevision: String,
        modelContainerIdentity: String
    ) -> Bool {
        metadata["cache_format_version"] == "1"
            && metadata["prompt_cache_format_version"] == PromptCacheKeyBuilder.formatVersion
            && metadata["model_id"] == modelID
            && metadata["prefix_token_count"] == String(prefixCount)
            && metadata["cache_state_signature"] == stateSignature
            && metadata["cache_layout_signature"] == layoutSignature
            && metadata["model_revision"] == modelRevision
            && metadata["tokenizer_revision"] == tokenizerRevision
            && metadata["template_revision"] == templateRevision
            && metadata["model_container_identity"] == modelContainerIdentity
    }
}

/// A service class that manages machine learning models for text and vision-language tasks.
/// This class handles model loading, caching, and text generation using various LLM and VLM models.
class LMService {
    
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
        let lease = try await InferenceRuntimeCoordinator.shared.acquire(.languageModel)

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
    func generate(model: LocalModel, messages: [MLXLMCommon.Chat.Message], tools: [ToolSpec] = []) async throws -> AsyncStream<Generation> {
        let lease = try await InferenceRuntimeCoordinator.shared.acquire(.languageModel)

        do {
            let modelContainer = try await load(model: model)
            let userInput = UserInput(
                chat: messages,
                processing: .init(resize: .init(width: 1024, height: 1024)),
                tools: tools,
            )

            let inner = try await modelContainer.perform { (context: ModelContext) in
                let parameters = GenerateParameters(
                    temperature: 0.7,
                    prefillStepSize: 256)
                let modelIdentity = ObjectIdentifier(context.model)
                let modelContainerIdentity = String(describing: modelIdentity)
                let modelRevision = PromptCacheKeyBuilder.modelRevision(
                    for: context.configuration)
                let tokenizerRevision = PromptCacheKeyBuilder.tokenizerRevision(
                    for: context.configuration)
                let templateRevision = PromptCacheKeyBuilder.templateRevision
                let fullInput = try await context.processor.prepare(input: userInput)
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
                            if let prefixCount = PromptPrefixPlanner.commonPrefixCount(
                                full: fullTokens, candidate: historyTokens)
                            {
                                let prefixTokens = Array(fullTokens.prefix(prefixCount))
                                let key = PromptCacheKeyBuilder.make(
                                    modelID: model.id,
                                    prefixTokens: prefixTokens,
                                    tools: tools,
                                    modelRevision: modelRevision,
                                    tokenizerRevision: tokenizerRevision,
                                    templateRevision: templateRevision)

                                if let snapshot = KVCacheManager.shared.cachedSnapshot(for: key) {
                                    let cached = snapshot.cache
                                    let stateSignature = KVCacheManager.stateSignature(for: cached)
                                    let cachedLayout = KVCacheManager.layout(for: cached)
                                    let expectedLayout: KVCacheManager.CacheLayout
                                    if let registered = KVCacheManager.shared.registeredLayout(
                                        for: model.id,
                                        modelIdentity: modelIdentity
                                    ) {
                                        expectedLayout = registered
                                    } else {
                                        do {
                                            // Empty caches do not expose tensor structure. A single-token
                                            // current-model prefill establishes the stable layout while
                                            // the layout descriptor ignores the growing sequence axis.
                                            guard let probeToken = prefixProbeToken(from: prefixTokens) else {
                                                throw PrefixCacheProbeError.emptyPrefix
                                            }
                                            let probeTokens = MLXArray([probeToken]).reshaped(1, -1)
                                            let probeInput = LMInput(
                                                text: .init(tokens: probeTokens),
                                                image: nil,
                                                video: nil)
                                            let probeCache = context.model.newCache(parameters: parameters)
                                            _ = try TokenIterator(
                                                input: probeInput,
                                                model: context.model,
                                                cache: probeCache,
                                                parameters: parameters)
                                            eval(probeCache)
                                            expectedLayout = KVCacheManager.layout(for: probeCache)
                                            KVCacheManager.shared.registerLayout(
                                                expectedLayout,
                                                for: model.id,
                                                modelIdentity: modelIdentity)
                                        } catch {
                                            KVCacheManager.shared.clear(for: key)
                                            throw error
                                        }
                                    }
                                    let hasCompatibleLayout = cached.allSatisfy {
                                        $0.offset == prefixCount
                                    } && KVCacheManager.layoutsCompatible(
                                        cached: cachedLayout,
                                        expected: expectedLayout)
                                    let hasCompatibleMetadata = PromptCacheMetadata.matches(
                                        snapshot.metadata,
                                        modelID: model.id,
                                        prefixCount: prefixCount,
                                        stateSignature: stateSignature,
                                        layoutSignature: KVCacheManager.layoutSignature(for: cached),
                                        modelRevision: modelRevision,
                                        tokenizerRevision: tokenizerRevision,
                                        templateRevision: templateRevision,
                                        modelContainerIdentity: modelContainerIdentity)
                                    if hasCompatibleLayout && hasCompatibleMetadata {
                                        let suffixTokens = makeSuffixTokens(
                                            fullTokens: fullInput.text.tokens, prefixCount: prefixCount)
                                        generationInput = LMInput(
                                            text: .init(tokens: suffixTokens),
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
                                            tokens: MLXArray(prefixTokens).reshaped(1, -1)),
                                        image: nil,
                                        video: nil)
                                    _ = try TokenIterator(
                                        input: prefixInput,
                                        model: context.model,
                                        cache: built,
                                        parameters: parameters)
                                    eval(built)
                                    KVCacheManager.shared.registerLayout(
                                        KVCacheManager.layout(for: built),
                                        for: model.id,
                                        modelIdentity: modelIdentity)
                                    KVCacheManager.shared.save(
                                        cache: built,
                                        for: key,
                                        metadata: [
                                            "prompt_cache_format_version": PromptCacheKeyBuilder.formatVersion,
                                            "model_id": model.id,
                                            "prefix_token_count": String(prefixCount),
                                            "model_revision": modelRevision,
                                            "tokenizer_revision": tokenizerRevision,
                                            "template_revision": templateRevision,
                                            "model_container_identity": modelContainerIdentity,
                                        ])

                                    let suffixTokens = makeSuffixTokens(
                                        fullTokens: fullInput.text.tokens, prefixCount: prefixCount)
                                    generationInput = LMInput(
                                        text: .init(tokens: suffixTokens),
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
                        promptTokenCount: generationInput.text.tokens.size,
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
    func generate(model: LocalModel, messages: [MLXLMCommon.Chat.Message], tools: [ToolSpec] = []) async throws -> String {
        var output = ""
        for await segement in try await generate(model: model, messages: messages, tools: tools) {
            try Task.checkCancellation()
            if let chunk = segement.chunk {
                output.append(chunk)
            }
        }
        try Task.checkCancellation()
        return output
    }
    
    func generate(model: LocalModel, messages: [Message], tools: [ToolSpec] = []) async throws -> String {
        return try await generate(model: model, messages: messages.compactMap{ toMessage($0) }, tools: tools)
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
