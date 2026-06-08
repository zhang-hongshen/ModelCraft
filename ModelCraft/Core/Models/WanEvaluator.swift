//
//  WanEvaluator.swift
//  ModelCraft
//
//  Created by Hongshen on 9/4/26.
//


import Foundation
import MLX

@Observable
@MainActor
class WanEvaluator {
    
    private let modelFactory = WanModelFactory()

    /// Generate a video and return a ``AsyncThrowingStream``
    func generate(prompt: String, sampler: String? = nil) async throws -> MLXArray {
        var finalVideo: MLXArray?
        for try await video in try await generate(prompt: prompt, sampler: sampler) {
            finalVideo = video
        }
        guard let finalVideo = finalVideo  else {
            throw NSError(domain: "WanEvaluator", code: -1)
        }
        return finalVideo
    }
    
    /// Generate a video and return a ``AsyncThrowingStream``
    func generate(prompt: String, sampler: String? = nil) async throws -> AsyncThrowingStream<MLXArray, Error> {
        let model = try await modelFactory.load()
        var parameters = modelFactory.configuration.defaultParameters()
        parameters.prompt = prompt
        return AsyncThrowingStream { continuation in
            Task {
                let latents = try model.generateLatents(parameters)
                var lastLatent: MLXArray?
                for await latent in latents {
                    lastLatent = nil
                    MLX.eval(latent)
                    lastLatent = latent
                    continuation.yield(try model.decode(latent))
                }
                if let lastLatent = lastLatent {
                    continuation.yield(try model.decode(lastLatent))
                }
                continuation.finish()
            }
        }
    }
}


actor WanModelFactory {
    enum LoadState {
        case idle
        case loading(Task<Wan, Error>)
        case loaded(Wan)
    }

    public nonisolated let configuration: WanConfiguration
    public nonisolated let conserveMemory: Bool
    
    private var loadState: LoadState = .idle
    
    init(configuration: WanConfiguration = .presetT2V1_3B) {
        self.configuration = configuration
        self.conserveMemory = Memory.memoryLimit < 8 * 1024 * 1024 * 1024

        if conserveMemory {
            print("conserving memory")
            Memory.cacheLimit = 1 * 1024 * 1024
            Memory.memoryLimit = 3 * 1024 * 1024 * 1024
        } else {
            Memory.cacheLimit = 256 * 1024 * 1024
        }
    }
    
    func load() async throws -> Wan {
        switch loadState {
        case .idle:
            let task = Task {
                try await configuration.download()
                let model: Wan
                if configuration.modelType == .textToVideo {
                    model = try WanT2V(configuration: configuration)
                } else {
                    model = try WanI2V(configuration: configuration)
                }
                if !conserveMemory {
                    try model.ensureLoaded()
                }
                return model
            }
            
            loadState = .loading(task)
            let model = try await task.value
            if conserveMemory {
                self.loadState = .idle
            } else {
                self.loadState = .loaded(model)
            }
            return model
        case .loading(let task):
            return try await task.value
        case .loaded(let model):
            return model
        }
    }
}
