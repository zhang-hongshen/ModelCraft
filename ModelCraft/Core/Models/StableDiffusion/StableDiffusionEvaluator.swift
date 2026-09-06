//
//  StableDiffusionEvaluator.swift
//  ModelCraft
//
//  Created by Hongshen on 7/4/26.
//

import Foundation
import CoreImage
import MLX

enum StableDiffusionProgress: Equatable, Sendable {
    case downloading(percent: Int)
    case loading
    case generating(completed: Int, total: Int)
    case decoding
    case saving
}

typealias StableDiffusionProgressHandler = @Sendable (StableDiffusionProgress) async -> Void

final class StableDiffusionEvaluator: @unchecked Sendable {

    static let shared = StableDiffusionEvaluator()

    private let modelFactory = StableDiffusionModelFactory()

    var defaultParameters: StableDiffusionEvaluateParameters {
        var parameters = modelFactory.configuration.defaultParameters()
        parameters.steps = modelFactory.generationSteps
        return parameters
    }

    nonisolated private func toCGImage(_ array: MLXArray) -> CGImage {
        let raster = (array * 255).asType(.uint8).squeezed()
        return StableDiffusionImage(raster).asCGImage()
    }
    
    
    func generate(
        prompt: String,
        progress: @escaping StableDiffusionProgressHandler = { _ in }
    ) async throws -> CGImage {
        if modelFactory.requiresDownload {
            await progress(.downloading(percent: 0))
        } else {
            await progress(.loading)
        }
        
        let stream = try await generate(
            prompt: prompt,
            showProgress: false,
            progress: progress
        )
        
        var finalImage: CGImage?
        
        for try await image in stream {
            finalImage = image
        }
        
        guard let finalImage else {
            throw NSError(domain: "StableDiffusionEvaluator", code: -1)
        }
        
        return finalImage
    }
    
    func generate(
        prompt: String,
        showProgress: Bool,
        progress: @escaping StableDiffusionProgressHandler = { _ in }
    ) async throws
        -> AsyncThrowingStream<CGImage, Error> {
        let lease = try await InferenceRuntimeCoordinator.shared.acquire()

        do {
            let container = try await modelFactory.load(progress: progress)
            let releasesComponentsBetweenStages =
                modelFactory.releasesComponentsBetweenStages
            var configuredParameters = defaultParameters
            configuredParameters.prompt = prompt
            let parameters = configuredParameters
            return AsyncThrowingStream { continuation in
                let task = Task {
                    let (progressStream, progressContinuation) =
                        AsyncStream.makeStream(of: StableDiffusionProgress.self)
                    let progressTask = Task {
                        for await value in progressStream {
                            await progress(value)
                        }
                    }
                    do {
                        try await container.perform { generator in
                            try Task.checkCancellation()

                            var latents: DenoiseIterator? = try generator.generateLatents(
                                parameters: parameters)
                            let totalSteps = latents?.underestimatedCount ?? parameters.steps
                            progressContinuation.yield(
                                .generating(completed: 0, total: totalSteps))
                            var finalLatent: MLXArray?
                            var index = 0
                            while let latent = latents?.next() {
                                try Task.checkCancellation()
                                eval(latent)
                                finalLatent = latent

                                if showProgress && !releasesComponentsBetweenStages
                                    && index % 10 == 0
                                {
                                    let preview = try generator.decode(xt: latent)
                                    eval(preview)
                                    continuation.yield(self.toCGImage(preview))
                                }
                                index += 1
                                progressContinuation.yield(
                                    .generating(completed: index, total: totalSteps))
                            }
                            latents = nil
                            Memory.clearCache()
                            try Task.checkCancellation()

                            guard let finalLatent else {
                                throw NSError(domain: "StableDiffusionEvaluator", code: -1)
                            }
                            progressContinuation.yield(.decoding)
                            let raster = try generator.decode(xt: finalLatent)
                            eval(raster)
                            try Task.checkCancellation()
                            continuation.yield(self.toCGImage(raster))
                        }
                        progressContinuation.finish()
                        await progressTask.value
                        await lease.release()
                        continuation.finish()
                    } catch {
                        progressContinuation.finish()
                        progressTask.cancel()
                        await lease.release()
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { @Sendable _ in
                    task.cancel()
                }
            }
        } catch {
            await lease.release()
            throw error
        }
    }
}


/// Async model factory
actor StableDiffusionModelFactory {

    private enum State {
        case idle
        case loading(Task<StableDiffusionModelContainer, Error>)
        case loaded(StableDiffusionModelContainer)
    }

    public nonisolated let configuration: StableDiffusionConfiguration

    /// if true we show UI that lets users see the intermediate steps
    public nonisolated let canShowProgress: Bool

    /// if true we show UI to give negative text
    public nonisolated let canUseNegativeText: Bool

    public nonisolated let releasesComponentsBetweenStages: Bool

    public nonisolated let generationSteps: Int

    private let loadConfiguration: LoadConfiguration
    private let profile: StableDiffusionRuntimeProfile
    private var state = State.idle

    public nonisolated var requiresDownload: Bool {
        !configuration.isDownloaded()
    }

    init(configuration: StableDiffusionConfiguration = .presetSDXLTurbo) {
        let defaultParameters = configuration.defaultParameters()
        let profile = StableDiffusionRuntimeProfile.recommended(
            physicalMemory: ProcessInfo.processInfo.physicalMemory)
        var configuredLoad = profile.loadConfiguration
        configuredLoad.releasesComponentsBetweenStages =
            profile.releasesComponentsBetweenStages
        let loadConfiguration = configuredLoad
        self.canShowProgress = defaultParameters.steps > 4
        self.canUseNegativeText = defaultParameters.cfgWeight > 1
        self.configuration = configuration
        self.releasesComponentsBetweenStages = profile.releasesComponentsBetweenStages
        self.generationSteps = profile.generationSteps
        self.loadConfiguration = loadConfiguration
        self.profile = profile
    }

    public func load(progress: @escaping StableDiffusionProgressHandler) async throws
        -> StableDiffusionModelContainer
    {
        try Task.checkCancellation()
        switch state {
        case .idle:
            let task = Task { try await loadModel(progress: progress) }
            state = .loading(task)
            do {
                let container = try await waitForLoad(task)
                state = .loaded(container)
                return container
            } catch {
                state = .idle
                throw error
            }
        case .loading(let task):
            return try await waitForLoad(task)
        case .loaded(let container):
            await progress(.loading)
            return container
        }
    }

    private func waitForLoad(
        _ task: Task<StableDiffusionModelContainer, Error>
    ) async throws -> StableDiffusionModelContainer {
        try await withTaskCancellationHandler {
            let container = try await task.value
            try Task.checkCancellation()
            return container
        } onCancel: {
            task.cancel()
        }
    }

    private func loadModel(
        progress: @escaping StableDiffusionProgressHandler
    ) async throws -> StableDiffusionModelContainer {
        do {
            if configuration.isDownloaded() {
                await progress(.loading)
            } else {
                let downloadProgress = AsyncThrowingStream<Int, Error> { continuation in
                    let task = Task {
                        do {
                            try await configuration.download { value in
                                continuation.yield(Int(value.fractionCompleted * 100))
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { @Sendable _ in task.cancel() }
                }
                for try await percent in downloadProgress {
                    await progress(.downloading(percent: percent))
                }
                await progress(.loading)
            }
        } catch {
            let error = error as NSError
            guard error.domain == NSURLErrorDomain,
                  error.code == NSURLErrorNotConnectedToInternet else {
                throw error
            }
        }

        try Task.checkCancellation()
        let container = try StableDiffusionModelContainer
            .createTextToImageGenerator(
                configuration: configuration,
                loadConfiguration: loadConfiguration)
        try await container.perform { model in
            if !profile.releasesComponentsBetweenStages {
                try model.ensureLoaded()
            }
        }
        try Task.checkCancellation()
        return container
    }

}
