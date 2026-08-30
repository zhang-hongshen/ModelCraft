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
        
        var finalImage: MLXArray?
        
        for try await image in stream {
            finalImage = image
        }
        
        guard let finalImage else {
            throw NSError(domain: "StableDiffusionEvaluator", code: -1)
        }
        
        return toCGImage(finalImage)
    }
    
    func generate(prompt: String, showProgress: Bool) async throws
        -> AsyncThrowingStream<MLXArray, Error> {
        let lease = try await InferenceRuntimeCoordinator.shared.acquire(.stableDiffusion)

        do {
        let container = try await modelFactory.load()
        return AsyncThrowingStream { continuation in
            let task = Task {
                defer {
                    Task { await lease.release() }
                }

                do {
                    try await container.performTwoStage { generator in
                    // The parameters that control the generation of the image. See
                    // EvaluateParameters for more information. For example, adjusting
                    // the latentSize parameter will change the size of the generated
                    // image. `imageCount` could be used to generate a gallery of
                    // images at the same time.
                    var parameters = modelFactory.configuration.defaultParameters()
                    parameters.prompt = prompt
                    
                    // Per measurement each step consumes memory that we want to conserve. Trade
                    // off steps (quality) for memory.
                    if modelFactory.conserveMemory {
                        parameters.steps = 1
                    }
                    // Note: The optionals are used to discard parts of the model
                    // as it runs. This is used to conserve memory in devices
                    // with less memory.
                    
                    // Generate the latent images. This is fast as it is just generating
                    // the graphs that will be evaluated below.
                    let latents: DenoiseIterator? = generator.generateLatents(parameters: parameters)
                    
                    // When conserveMemory is true this will discard the first part of
                    // the model and just evaluate the decode portion.
                    return (generator.detachedDecoder(), latents)
                    
                } second: { decoder, latents in
                    var lastXt: MLXArray?
                    for (i, xt) in latents!.enumerated() {
                        lastXt = nil
                        eval(xt)
                        lastXt = xt
                        
                        if showProgress, i % 10 == 0 {
                            continuation.yield(decoder(xt))
                        }
                        
                    }
                    
                    if let lastXt {
                        continuation.yield(decoder(lastXt))
                    }
                    continuation.finish()
                }
                } catch {
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
            return value
        }
    }

    private func waitForLoad(id: UUID, task: Task<Value, Error>) async throws -> Value {
        try await withTaskCancellationHandler {
            do {
                let value = try await task.value
                completeLoad(id: id, value: value)
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

    public nonisolated let conserveMemory: Bool

    init(configuration: StableDiffusionConfiguration = .presetSDXLTurbo) {
        let defaultParameters = configuration.defaultParameters()
        let profile = StableDiffusionRuntimeProfile.recommended(
            physicalMemory: ProcessInfo.processInfo.physicalMemory)
        let conserveMemory = Memory.memoryLimit < 8 * 1024 * 1024 * 1024
        self.canShowProgress = defaultParameters.steps > 4
        self.canUseNegativeText = defaultParameters.cfgWeight > 1
        self.configuration = configuration
        self.conserveMemory = conserveMemory
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
                configuration: configuration, loadConfiguration: profile.loadConfiguration)
            try Task.checkCancellation()

            try await container.perform { model in
                if !conserveMemory {
                    model.ensureLoaded()
                }
            }

            return container
        }
    }

    public func load() async throws
        -> StableDiffusionModelContainer<TextToImageGenerator>
    {
        try await loadState.load()
    }

}
