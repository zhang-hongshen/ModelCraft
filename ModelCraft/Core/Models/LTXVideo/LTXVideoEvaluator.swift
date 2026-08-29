//
//  LTXVideoEvaluator.swift
//  ModelCraft
//

import Foundation

import MLX

actor LTXVideoEvaluator {
    private let modelFactory = LTXVideoModelFactory()

    public func generate(prompt: String) async throws -> MLXArray {
        let lease = await InferenceRuntimeCoordinator.shared.acquire(.ltxVideo)
        do {
            let model = try await modelFactory.load()
            let parameters = model.configuration.defaultParameters(prompt)
            let result = try await model.generate(parameters)
            await lease.release()
            return result
        } catch {
            await lease.release()
            throw error
        }
    }
}

actor LTXVideoModelFactory {
    enum State {
        case unloaded
        case loading(Task<LTXVideo, Error>)
        case loaded(LTXVideo)
    }

    public nonisolated let configuration: LTXVideoConfiguration
    public nonisolated let conserveMemory: Bool
    private var state: State = .unloaded

    init(configuration: LTXVideoConfiguration = .ltxv2BDistilled) {
        self.configuration = configuration
        self.conserveMemory = Memory.memoryLimit < 12 * 1024 * 1024 * 1024
    }

    func load() async throws -> LTXVideo {
        switch state {
        case .loaded(let model):
            return model
        case .loading(let task):
            return try await task.value
        case .unloaded:
            let task = Task<LTXVideo, Error> {
                LTXVideo(configuration: configuration)
            }
            state = .loading(task)
            do {
                let model = try await task.value
                state = conserveMemory ? .unloaded : .loaded(model)
                return model
            } catch {
                state = .unloaded
                throw error
            }
        }
    }

    func cleanup() {
        if case .loaded(let model) = state {
            model.cleanup()
        }
        state = .unloaded
        Memory.clearCache()
    }
}
