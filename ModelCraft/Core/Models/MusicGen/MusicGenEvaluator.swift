//
//  MusicGenConfiguration.swift
//  ModelCraft
//
//  Created by Hongshen on 28/5/26.
//

import Foundation
import MLX


class MusicGenEvaluator {
    
    private let modelFactory = MusicGenModelFactory()
    
    func generate(prompt: String) async throws -> MLXArray {
        let lease = try await InferenceRuntimeCoordinator.shared.acquire(.musicGen)
        do {
            let model = try await modelFactory.load()
            var parameters = modelFactory.configuration.defaultParameters()
            parameters.prompt = prompt
            let result = model.generate(parameters)
            await lease.release()
            return result
        } catch {
            await lease.release()
            throw error
        }
    }
    
    func saveAudio(to url: URL, audio: MLXArray) throws {
        try MusicGenIO.saveAudio(to: url, audio: audio,
                             samplingRate: modelFactory.configuration.audioEncoderParameters.samplingRate)
    }
}


actor MusicGenModelFactory {
    enum LoadState {
        case idle
        case loading(Task<MusicGen, Error>)
        case loaded(MusicGen)
    }

    public nonisolated let configuration: MusicGenConfiguration
    public nonisolated let conserveMemory: Bool
    
    private var loadState: LoadState = .idle
    
    init(configuration: MusicGenConfiguration = .small) {
        self.configuration = configuration
        self.conserveMemory = Memory.memoryLimit < 8 * 1024 * 1024 * 1024

        if conserveMemory {
            print("conserving memory")
        }
    }
    
    func load() async throws -> MusicGen {
        switch loadState {
        case .idle:
            let task = Task {
                try await configuration.download()
                let model = try MusicGen(configuration: configuration)
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
