//
//  StableDiffusionEvaluator.swift
//  ModelCraft
//
//  Created by Hongshen on 7/4/26.
//

import Foundation
import CoreImage
import MLX

@Observable
@MainActor
class StableDiffusionEvaluator {

    private let modelFactory = ModelFactory()

    nonisolated private func toCGImage(_ array: MLXArray) -> CGImage {
        let raster = (array * 255).asType(.uint8).squeezed()
        return MLXImage(raster).asCGImage()
    }
    
    
    func generate(prompt: String, negativePrompt: String = "") async throws -> CGImage {
        
        let stream = try await generate(
            prompt: prompt,
            negativePrompt: negativePrompt,
            showProgress: false
        )
        
        var finalImage: CGImage?
        
        for try await image in stream {
            finalImage = image
        }
        
        guard let finalImage else {
            throw NSError(domain: "StableDiffusion", code: -1)
        }
        
        return finalImage
    }
    
    func generate(prompt: String, negativePrompt: String, showProgress: Bool) async throws
        -> AsyncThrowingStream<CGImage, Error> {
        let container = try await modelFactory.load()
        return AsyncThrowingStream { continuation in
            Task {
                try await container.performTwoStage { generator in
                    // The parameters that control the generation of the image. See
                    // EvaluateParameters for more information. For example, adjusting
                    // the latentSize parameter will change the size of the generated
                    // image. `imageCount` could be used to generate a gallery of
                    // images at the same time.
                    var parameters = modelFactory.configuration.defaultParameters()
                    parameters.prompt = prompt
                    parameters.negativePrompt = negativePrompt
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
                            continuation.yield(toCGImage(decoder(xt)))
                        }
                        
                    }
                    
                    if let lastXt {
                        continuation.yield(toCGImage(decoder(lastXt)))
                    }
                    continuation.finish()
                }
            }
        }
                
    }
}


/// Async model factory
actor ModelFactory {

    enum LoadState {
        case idle
        case loading(Task<StableDiffusionModelContainer<TextToImageGenerator>, Error>)
        case loaded(StableDiffusionModelContainer<TextToImageGenerator>)
    }

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

    private var loadState = LoadState.idle
    private var loadConfiguration = LoadConfiguration(float16: true, quantize: false)

    public nonisolated let conserveMemory: Bool

    init(configuration: StableDiffusionConfiguration = .presetSDXLTurbo) {
        let defaultParameters = configuration.defaultParameters()
        self.canShowProgress = defaultParameters.steps > 4
        self.canUseNegativeText = defaultParameters.cfgWeight > 1
        self.configuration = configuration
        // this will be true e.g. if the computer has 8G of memory or less
        self.conserveMemory = Memory.memoryLimit < 8 * 1024 * 1024 * 1024

        if conserveMemory {
            print("conserving memory")
            loadConfiguration.quantize = true
            Memory.cacheLimit = 1 * 1024 * 1024
            Memory.memoryLimit = 3 * 1024 * 1024 * 1024
        } else {
            Memory.cacheLimit = 256 * 1024 * 1024
        }
    }

    public func load() async throws
        -> StableDiffusionModelContainer<TextToImageGenerator>
    {
        switch loadState {
        case .idle:
            let task = Task {
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

                let container = try StableDiffusionModelContainer<TextToImageGenerator>.createTextToImageGenerator(
                    configuration: configuration, loadConfiguration: loadConfiguration)

                await container.setConserveMemory(conserveMemory)

                try await container.perform { model in
                    if !conserveMemory {
                        model.ensureLoaded()
                    }
                }

                return container
            }
            self.loadState = .loading(task)

            let container = try await task.value

            if conserveMemory {
                // if conserving memory return the model but do not keep it in memory
                self.loadState = .idle
            } else {
                // cache the model in memory to make it faster to run with new prompts
                self.loadState = .loaded(container)
            }

            return container

        case .loading(let task):
            let generator = try await task.value
            return generator

        case .loaded(let generator):
            return generator
        }
    }

}
