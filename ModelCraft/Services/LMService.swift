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

import Tokenizers


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
    private func load(model: LocalModel) async throws -> ModelContainer {
        
        // Return cached model if available to avoid reloading
        if let container = modelCache.object(forKey: model.id as NSString) {
            return container
        } else {
            // Load model
            let container = try await loadModelContainer(hub: .shared, configuration: ModelConfiguration(id: model.id))
            
            // Cache the loaded model for future use
            modelCache.setObject(container, forKey: model.id as NSString)
            
            return container
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
        // Load or retrieve model from cache
        let modelContainer = try await load(model: model)
        
        // Prepare input for model processing
        
        let userInput = UserInput(
            chat: messages,
            processing: .init(resize: .init(width: 1024, height: 1024)),
            tools: tools,
        )
        
//        let userInput = UserInput(
//            chat: [messages.last!],
//            processing: .init(resize: .init(width: 1024, height: 1024)),
//            tools: tools,
//        )
        
        // Generate response using the model
        return try await modelContainer.perform { (context: ModelContext) in
            let userLMInput = try await context.processor.prepare(input: userInput)
            
            let parameters = GenerateParameters(temperature: 0.7)
            
//            var cache = context.model.newCache(parameters: parameters)
//            print("cache count \(cache.count)")
//            if messages.count > 1 {
//                let historyInput = UserInput(chat: Array(messages.dropLast()), tools: tools)
//                let key = "\(model.id)_\(historyInput.prompt.description)".sha256String
//                
//                if !KVCacheManager.shared.load(for: key, into: &cache) {
//                    let historyTokens = try await context.processor.prepare(input: historyInput).text.tokens
//
//                    _ = context.model(historyTokens.reshaped([1, -1]), cache: cache)
//                    
//                    KVCacheManager.shared.save(cache: cache, for: key)
//                }
//            }
            return try MLXLMCommon.generate(input: userLMInput, parameters: parameters, context: context)
//            return try MLXLMCommon.generate(
//                input: userLMInput, cache: cache,
//                parameters: parameters, context: context)
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
            if let chunk = segement.chunk {
                output.append(chunk)
            }
        }
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
        for url in message.attachments {
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
