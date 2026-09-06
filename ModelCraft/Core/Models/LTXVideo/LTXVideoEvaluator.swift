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
        duration: Int,
        progress: LTXVideoProgressHandler = { _ in }
    ) async throws -> MLXArray {
        try Task.checkCancellation()
        await progress(.preparing)
        try Task.checkCancellation()
        let lease = try await InferenceRuntimeCoordinator.shared.acquire()
        do {
            let model = try await modelFactory.load()
            try Task.checkCancellation()
            let parameters = model.configuration.makeParameters(
                prompt, ratio, resolution, duration)
            let result = try await model.generate(parameters, progress: progress)
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
        try Task.checkCancellation()
        switch state {
        case .loaded(let model):
            return model
        case .loading(let task):
            do {
                return try await waitForLoad(task)
            } catch {
                state = .unloaded
                throw error
            }
        case .unloaded:
            let task = Task<LTXVideo, Error> {
                try await configuration.download()
                try Task.checkCancellation()
                return LTXVideo(configuration: configuration, runtimeProfile: runtimeProfile)
            }
            state = .loading(task)
            do {
                let model = try await waitForLoad(task)
                state = .loaded(model)
                return model
            } catch {
                state = .unloaded
                throw error
            }
        }
    }

    private func waitForLoad(_ task: Task<LTXVideo, Error>) async throws -> LTXVideo {
        try await withTaskCancellationHandler {
            let model = try await task.value
            try Task.checkCancellation()
            return model
        } onCancel: {
            task.cancel()
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
