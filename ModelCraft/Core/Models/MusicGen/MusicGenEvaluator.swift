//
//  MusicGenEvaluator.swift
//  ModelCraft
//
//  Created by Hongshen on 28/5/26.
//

import Foundation
import MLX


final class MusicGenEvaluator {

    private let modelFactory = MusicGenModelFactory()
    
    func generate(prompt: String) async throws -> MLXArray {
        try Task.checkCancellation()
        let lease = try await InferenceRuntimeCoordinator.shared.acquire()
        do {
            let model = try await modelFactory.load()
            try Task.checkCancellation()
            var parameters = modelFactory.configuration.defaultParameters()
            parameters.prompt = prompt
            let result = try model.generate(parameters)
            try Task.checkCancellation()
            await lease.release()
            return result
        } catch {
            await lease.release()
            throw error
        }
    }
    
    func saveAudio(to url: URL, audio: MLXArray) throws {
        try Task.checkCancellation()
        try MusicGenIO.saveAudio(to: url, audio: audio,
                             samplingRate: modelFactory.configuration.audioEncoderParameters.samplingRate)
        try Task.checkCancellation()
    }
}

actor MusicGenModelFactory {
    private enum LoadState {
        case idle
        case loading(Task<MusicGen, Error>)
        case loaded(MusicGen)
    }

    nonisolated let configuration: MusicGenConfiguration
    private let conserveMemory: Bool
    private var loadState = LoadState.idle

    init(configuration: MusicGenConfiguration = .small) {
        self.configuration = configuration
        self.conserveMemory = Memory.memoryLimit < 8 * 1024 * 1024 * 1024
    }

    func load() async throws -> MusicGen {
        try Task.checkCancellation()
        switch loadState {
        case .idle:
            let task = Task {
                try await configuration.download()
                try Task.checkCancellation()
                let model = try MusicGen(configuration: configuration)
                if !conserveMemory {
                    try model.ensureLoaded()
                }
                try Task.checkCancellation()
                return model
            }

            loadState = .loading(task)
            do {
                let model = try await waitForLoad(task)
                loadState = conserveMemory ? .idle : .loaded(model)
                return model
            } catch {
                loadState = .idle
                throw error
            }
        case .loading(let task):
            do {
                return try await waitForLoad(task)
            } catch {
                loadState = .idle
                throw error
            }
        case .loaded(let model):
            return model
        }
    }

    private func waitForLoad(_ task: Task<MusicGen, Error>) async throws -> MusicGen {
        try await withTaskCancellationHandler {
            let model = try await task.value
            try Task.checkCancellation()
            return model
        } onCancel: {
            task.cancel()
        }
    }
}
