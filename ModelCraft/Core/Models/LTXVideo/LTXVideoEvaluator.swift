//
//  LTXVideoEvaluator.swift
//  ModelCraft
//

import Foundation

import MLX

actor LTXVideoEvaluator {
    private let modelFactory = LTXVideoModelFactory()

    public func generate(
        prompt: String,
        ratio: LTXVideoAspectRatio,
        resolution: LTXVideoResolution,
        duration: Int
    ) async throws -> MLXArray {
        let lease = try await InferenceRuntimeCoordinator.shared.acquire(.ltxVideo)
        do {
            let model = try await modelFactory.load()
            let parameters = model.configuration.makeParameters(
                prompt, ratio, resolution, duration)
            let result = try await model.generate(parameters)
            await lease.release()
            return result
        } catch {
            await modelFactory.cleanup()
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
    nonisolated let runtimeProfile: LTXVideoRuntimeProfile
    private var state: State = .unloaded

    init(
        configuration: LTXVideoConfiguration = .ltxv2BDistilled,
        runtimeProfile: LTXVideoRuntimeProfile = .deviceDefault
    ) {
        self.configuration = configuration
        self.runtimeProfile = runtimeProfile
    }

    func load() async throws -> LTXVideo {
        switch state {
        case .loaded(let model):
            return model
        case .loading(let task):
            return try await task.value
        case .unloaded:
            let task = Task<LTXVideo, Error> {
                try await configuration.download()
                return LTXVideo(configuration: configuration, runtimeProfile: runtimeProfile)
            }
            state = .loading(task)
            do {
                let model = try await task.value
                state = .loaded(model)
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
