//
//  ModelContainer.swift
//  ModelCraft
//
//  Created by Hongshen on 4/5/26.
//

import MLX
import Foundation

// port of https://github.com/ml-explore/mlx-examples/blob/main/stable_diffusion/stable_diffusion/__init__.py

/// Iterator that produces latent images.
///
/// Created by:
///
/// - ``TextToImageGenerator/generateLatents(parameters:)``
/// - ``ImageToImageGenerator/generateLatents(image:parameters:strength:)``
public struct DenoiseIterator: Sequence, IteratorProtocol {

    let sd: StableDiffusion

    var xt: MLXArray

    let conditioning: MLXArray
    let cfgWeight: Float
    let textTime: (MLXArray, MLXArray)?

    var i: Int
    let steps: [(MLXArray, MLXArray)]

    init(
        sd: StableDiffusion, xt: MLXArray, t: Int, conditioning: MLXArray, steps: Int,
        cfgWeight: Float, textTime: (MLXArray, MLXArray)? = nil
    ) {
        self.sd = sd
        self.steps = sd.sampler.timeSteps(steps: steps, start: t, dType: sd.dType)
        self.i = 0
        self.xt = xt
        self.conditioning = conditioning
        self.cfgWeight = cfgWeight
        self.textTime = textTime
    }

    public var underestimatedCount: Int {
        steps.count
    }

    mutating public func next() -> MLXArray? {
        guard i < steps.count else {
            return nil
        }

        let (t, tPrev) = steps[i]
        i += 1

        xt = sd.step(
            xt: xt, t: t, tPrev: tPrev, conditioning: conditioning, cfgWeight: cfgWeight,
            textTime: textTime)
        return xt
    }
}

/// Type for the _decoder_ step.
public typealias ImageDecoder = (MLXArray) -> MLXArray

public protocol ImageGenerator {
    func ensureLoaded()

    /// Return a detached decoder -- this is useful if trying to conserve memory.
    ///
    /// The decoder can be used independently of the ImageGenerator to transform
    /// latents into raster images.
    func detachedDecoder() -> ImageDecoder

    /// the equivalent to the ``detachedDecoder()`` but without the detatching
    func decode(xt: MLXArray) -> MLXArray
}

/// Public interface for transforming a text prompt into an image.
///
/// Steps:
///
/// - ``generateLatents(parameters:)``
/// - evaluate each of the latents from the iterator
/// - ``ImageGenerator/decode(xt:)`` or ``ImageGenerator/detachedDecoder()`` to convert the final latent into an image
/// - use ``Image`` to save the image
public protocol TextToImageGenerator: ImageGenerator {
    func generateLatents(parameters: StableDiffusionEvaluateParameters) -> DenoiseIterator
}

/// Public interface for transforming a text prompt into an image.
///
/// Steps:
///
/// - ``generateLatents(image:parameters:strength:)``
/// - evaluate each of the latents from the iterator
/// - ``ImageGenerator/decode(xt:)`` or ``ImageGenerator/detachedDecoder()`` to convert the final latent into an image
/// - use ``Image`` to save the image
public protocol ImageToImageGenerator: ImageGenerator {
    func generateLatents(image: URL, parameters: StableDiffusionEvaluateParameters, strength: Float)
        -> DenoiseIterator
}

enum ModelContainerError: LocalizedError {
    /// Unable to create the particular type of model, e.g. it doesn't support image to image
    case unableToCreate(String, String)
    /// When operating in conserveMemory mode, it tried to use a model that had been discarded
    case modelDiscarded

    var errorDescription: String? {
        switch self {
        case .unableToCreate(let modelId, let generatorType):
            return String(
                localized:
                    "Unable to create a \(generatorType) with model ID '\(modelId)'. The model may not support this operation type."
            )
        case .modelDiscarded:
            return String(
                localized:
                    "The model has been discarded to conserve memory and is no longer available. Please recreate the model container."
            )
        }
    }
}

/// Container for models that guarantees single threaded access.
public actor StableDiffusionModelContainer<M> {

    enum State {
        case discarded
        case loaded(M)
    }

    var state: State

    /// if true this will discard the model in ``performTwoStage(first:second:)``
    var conserveMemory = false

    private init(model: M) {
        self.state = .loaded(model)
    }

    /// create a ``ModelContainer`` that supports ``TextToImageGenerator``
    static public func createTextToImageGenerator(
        configuration: StableDiffusionConfiguration, loadConfiguration: LoadConfiguration = .init()
    ) throws -> StableDiffusionModelContainer<TextToImageGenerator> {
        if let model = try configuration.textToImageGenerator(configuration: loadConfiguration) {
            return .init(model: model)
        } else {
            throw ModelContainerError.unableToCreate(configuration.id, "TextToImageGenerator")
        }
    }

    /// create a ``ModelContainer`` that supports ``ImageToImageGenerator``
    static public func createImageToImageGenerator(
        configuration: StableDiffusionConfiguration, loadConfiguration: LoadConfiguration = .init()
    ) throws -> StableDiffusionModelContainer<ImageToImageGenerator> {
        if let model = try configuration.imageToImageGenerator(configuration: loadConfiguration) {
            return .init(model: model)
        } else {
            throw ModelContainerError.unableToCreate(configuration.id, "ImageToImageGenerator")
        }
    }

    public func setConserveMemory(_ conserveMemory: Bool) {
        self.conserveMemory = conserveMemory
    }

    /// Perform an action on the model and/or tokenizer. Callers _must_ eval any `MLXArray` before returning as
    /// `MLXArray` is not `Sendable`.
    public func perform<R>(_ action: @Sendable (M) throws -> R) throws -> R {
        switch state {
        case .discarded:
            throw ModelContainerError.modelDiscarded
        case .loaded(let m):
            try action(m)
        }
    }

    /// Perform a two stage action where the first stage returns values passed to the second stage.
    ///
    /// If ``setConservativeMemory(_:)`` is `true` this will discard the model in between
    /// the `first` and `second` blocks. The container will have to be recreated if a caller
    /// wants to use it again.
    ///
    /// If `false` this will just run them in sequence and the container can be reused.
    ///
    /// Callers _must_ eval any `MLXArray` before returning as `MLXArray` is not `Sendable`.
    public func performTwoStage<R1, R2>(
        first: @Sendable (M) throws -> R1, second: @Sendable (R1) throws -> R2
    ) throws -> R2 {
        let r1 =
            switch state {
            case .discarded:
                throw ModelContainerError.modelDiscarded
            case .loaded(let m):
                try first(m)
            }
        if conserveMemory {
            self.state = .discarded
        }
        return try second(r1)
    }

}
