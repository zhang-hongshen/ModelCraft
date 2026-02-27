//
//  MLXService.swift
//  ModelCraft
//
//  Created by Hongshen on 23/2/26.
//

import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import CoreImage
import Tokenizers


/// A service class that manages machine learning models for text and vision-language tasks.
/// This class handles model loading, caching, and text generation using various LLM and VLM models.
class MLXService {
    
    static let shared = MLXService()
    
    /// List of available models that can be used for generation.
    /// Includes both language models (LLM) and vision-language models (VLM).
    static let availableModels: [LMModel] = [
        LMModel(name: "mlx-community/Llama-3.2-1B-Instruct-4bit", configuration: LLMRegistry.llama3_2_1B_4bit, type: .llm),
        LMModel(name: "mlx-community/Qwen2.5-VL-3B-Instruct-4bit", configuration: VLMRegistry.qwen2_5VL3BInstruct4Bit, type: .vlm),
    ]
    
    /// Cache to store loaded model containers to avoid reloading.
    private let modelCache = NSCache<NSString, ModelContainer>()
    
    /// Tracks the current model download progress.
    /// Access this property to monitor model download status.
    @MainActor
    private(set) var downloadQueue: [String: Progress] = [:]
    
    /// Loads a model from the hub or retrieves it from cache.
    /// - Parameter model: The model configuration to load
    /// - Returns: A ModelContainer instance containing the loaded model
    /// - Throws: Errors that might occur during model loading
    private func load(model: LMModel) async throws -> ModelContainer {
        
        // Set GPU memory limit to prevent out of memory issues
        Memory.cacheLimit = 20 * 1024 * 1024
        
        // Return cached model if available to avoid reloading
        if let container = modelCache.object(forKey: model.name as NSString) {
            return container
        } else {
            // Select appropriate factory based on model type
            let factory: ModelFactory =
            switch model.type {
            case .llm:
                LLMModelFactory.shared
            case .vlm:
                VLMModelFactory.shared
            }
            
            // Load model and track download progress
            let container = try await factory.loadContainer(
                hub: .default, configuration: model.configuration
            ) { progress in
                Task { @MainActor in
                    self.downloadQueue[model.name] = progress
                    print("progress \(progress.fractionCompleted)")
                    if progress.isFinished {
                        self.downloadQueue.removeValue(forKey: model.name)
                    }
                }
            }
            
            // Cache the loaded model for future use
            modelCache.setObject(container, forKey: model.name as NSString)
            
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
    func generate(model: LMModel, messages: [Message], tools: [ToolSpec] = []) async throws -> AsyncStream<Generation> {
        // Load or retrieve model from cache
        let modelContainer = try await load(model: model)
        // Map app-specific Message type to Chat.Message for model input
        let chat = messages.map{ toMessage($0) }
        
        // Prepare input for model processing
        let userInput = UserInput(
            chat: chat,
            processing: .init(resize: .init(width: 1024, height: 1024)),
            tools: tools,
        )
        
        // Generate response using the model
        return try await modelContainer.perform { (context: ModelContext) in
            let lmInput = try await context.processor.prepare(input: userInput)
            let parameters = GenerateParameters(temperature: 0.7)
            
            return try MLXLMCommon.generate(
                input: lmInput, parameters: parameters, context: context)
        }
    }
    
    
    func generate(model: LMModel, messages: [Message], tools: [ToolSpec] = []) async throws -> String {
        // Load or retrieve model from cache
        let modelContainer = try await load(model: model)
        
        // Map app-specific Message type to Chat.Message for model input
        let chat = messages.map{ toMessage($0) }
        
        // Prepare input for model processing
        let userInput = UserInput(
            chat: chat,
            processing: .init(resize: .init(width: 1024, height: 1024)),
            tools: tools,
        )
        
        // Generate response using the model
        return try await modelContainer.perform { (context: ModelContext) in
            let lmInput = try await context.processor.prepare(input: userInput)
            let parameters = GenerateParameters(temperature: 0.7)
            
            let result = try MLXLMCommon.generate(
                input: lmInput, parameters: parameters, context: context)
            var output = ""
            for await segment in result {
                output += segment.chunk ?? ""
            }
            return output
        }
    }
    
}

extension MLXService {
    
    func toMessage(_ message: Message) -> MLXLMCommon.Chat.Message {
        let role: MLXLMCommon.Chat.Message.Role =
            switch message.role {
            case .assistant:
                    .assistant
            case .user:
                    .user
            case .system:
                    .system
            case .tool:
                    .tool
            }

        // Process any attached media for VLM models
        
        let images: [UserInput.Image] = message.images.compactMap{ imageData in
            guard let ciImage = CIImage(data: imageData) else {
                return nil
            }
            return .ciImage(ciImage)
        }
        let videos: [UserInput.Video] = []
//            videos = message.videos.map { videoURL in .url(videoURL) }

        return MLXLMCommon.Chat.Message(role: role, content: message.content, images: images, videos: videos)
    }
}
