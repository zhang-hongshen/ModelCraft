//
//  StableDiffusionEvaluator.swift
//  ModelCraft
//
//  Created by Hongshen on 7/4/26.
//

import Foundation
import CoreImage
import MLX


final class StableDiffusionEvaluator: @unchecked Sendable {

    static let shared = StableDiffusionEvaluator()

    private let modelFactory = StableDiffusionModelFactory()

    nonisolated private func toCGImage(_ array: MLXArray) -> CGImage {
        let raster = (array * 255).asType(.uint8).squeezed()
        return StableDiffusionImage(raster).asCGImage()
    }
    
    
    func generate(prompt: String) async throws -> CGImage {
        
        let stream = try await generate(
            prompt: prompt,
            showProgress: false
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
    
    func generate(prompt: String, showProgress: Bool) async throws
        -> AsyncThrowingStream<CGImage, Error> {
        let lease = try await InferenceRuntimeCoordinator.shared.acquire(.stableDiffusion)

        do {
            let container = try await modelFactory.load()
            let configuration = modelFactory.configuration
            let releasesComponentsBetweenStages =
                modelFactory.releasesComponentsBetweenStages
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        try await container.perform { generator in
                            try Task.checkCancellation()
                            var parameters = configuration.defaultParameters()
                            parameters.prompt = prompt

                            var latents: DenoiseIterator? = try generator.generateLatents(
                                parameters: parameters)
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
                            }
                            latents = nil
                            Memory.clearCache()
                            try Task.checkCancellation()

                            guard let finalLatent else {
                                throw NSError(domain: "StableDiffusionEvaluator", code: -1)
                            }
                            let raster = try generator.decode(xt: finalLatent)
                            eval(raster)
                            try Task.checkCancellation()
                            continuation.yield(self.toCGImage(raster))
                        }
                        await lease.release()
                        continuation.finish()
                    } catch {
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


actor StableDiffusionLoadState<Value: Sendable> {

    private enum State {
        case idle
        case loading(id: UUID, task: Task<Value, Error>)
        case loaded(Value)
    }

    private let loader: @Sendable () async throws -> Value
    private var state = State.idle

    init(loader: @escaping @Sendable () async throws -> Value) {
        self.loader = loader
    }

    func load() async throws -> Value {
        try Task.checkCancellation()
        switch state {
        case .idle:
            let id = UUID()
            let task = Task {
                try await loader()
            }
            state = .loading(id: id, task: task)
            return try await waitForLoad(id: id, task: task)

        case .loading(let id, let task):
            return try await waitForLoad(id: id, task: task)

        case .loaded(let value):
            try Task.checkCancellation()
            return value
        }
    }

    private func waitForLoad(id: UUID, task: Task<Value, Error>) async throws -> Value {
        try await withTaskCancellationHandler {
            do {
                let value = try await task.value
                completeLoad(id: id, value: value)
                try Task.checkCancellation()
                return value
            } catch {
                failLoad(id: id)
                throw error
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func completeLoad(id: UUID, value: Value) {
        guard case let .loading(currentID, _) = state, currentID == id else {
            return
        }
        state = .loaded(value)
    }

    private func failLoad(id: UUID) {
        guard case let .loading(currentID, _) = state, currentID == id else {
            return
        }
        state = .idle
    }
}


/// Async model factory
actor StableDiffusionModelFactory {

    enum SDError: LocalizedError {
        case unableToLoad

        var errorDescription: String? {
            switch self {
            case .unableToLoad:
                return String(
                    localized:
                        "Unable to load the Stable Diffusion model. Please check your internet connection or available storage space."
                )
            }
        }
    }

    public nonisolated let configuration: StableDiffusionConfiguration

    /// if true we show UI that lets users see the intermediate steps
    public nonisolated let canShowProgress: Bool

    /// if true we show UI to give negative text
    public nonisolated let canUseNegativeText: Bool

    private let loadState: StableDiffusionLoadState<StableDiffusionModelContainer<TextToImageGenerator>>

    public nonisolated let releasesComponentsBetweenStages: Bool

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
        self.loadState = StableDiffusionLoadState {
            try Task.checkCancellation()

            do {
                try await configuration.download()
            } catch {
                let nserror = error as NSError
                if nserror.domain == NSURLErrorDomain
                    && nserror.code == NSURLErrorNotConnectedToInternet
                {
                    // Internet connection appears to be offline -- fall back to loading from
                    // the local directory
                } else {
                    throw error
                }
            }

            try Task.checkCancellation()
            let container = try StableDiffusionModelContainer<TextToImageGenerator>.createTextToImageGenerator(
                configuration: configuration, loadConfiguration: loadConfiguration)
            try Task.checkCancellation()

            try await container.perform { model in
                if !profile.releasesComponentsBetweenStages {
                    try model.ensureLoaded()
                }
            }
            try Task.checkCancellation()

            return container
        }
    }

    public func load() async throws
        -> StableDiffusionModelContainer<TextToImageGenerator>
    {
        try await loadState.load()
    }

}
