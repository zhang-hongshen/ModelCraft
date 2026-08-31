//
//  ModelContainer.swift
//  ModelCraft
//
//  Created by Hongshen on 4/5/26.
//

import MLX
import Foundation

// port of https://github.com/ml-explore/mlx-examples/blob/main/stable_diffusion/stable_diffusion/__init__.py

struct StableDiffusionConditioningKey: Hashable, Sendable {
    let modelID: String
    let prompt: String
    let negativePrompt: String
    let cfgWeight: Float
    let imageCount: Int
}

struct StableDiffusionConditioningCache<Value> {
    private var entry: (key: StableDiffusionConditioningKey, value: Value)?

    init() {}

    mutating func value(for key: StableDiffusionConditioningKey) -> Value? {
        guard entry?.key == key else {
            return nil
        }
        return entry?.value
    }

    mutating func insert(_ value: Value, for key: StableDiffusionConditioningKey) {
        entry = (key, value)
    }
}

struct StableDiffusionDenoiser {
    typealias Step = (
        MLXArray, MLXArray, MLXArray, MLXArray, Float, (MLXArray, MLXArray)?
    ) -> MLXArray

    private let step: Step

    init(_ step: @escaping Step) {
        self.step = step
    }

    func callAsFunction(
        xt: MLXArray, t: MLXArray, tPrev: MLXArray, conditioning: MLXArray,
        cfgWeight: Float, textTime: (MLXArray, MLXArray)?
    ) -> MLXArray {
        step(xt, t, tPrev, conditioning, cfgWeight, textTime)
    }
}

/// Iterator that produces latent images.
///
/// Created by:
///
/// - ``TextToImageGenerator/generateLatents(parameters:)``
/// - ``ImageToImageGenerator/generateLatents(image:parameters:strength:)``
public struct DenoiseIterator: Sequence, IteratorProtocol {

    let denoiser: StableDiffusionDenoiser

    var xt: MLXArray

    let conditioning: MLXArray
    let cfgWeight: Float
    let textTime: (MLXArray, MLXArray)?

    var i: Int
    let steps: [(MLXArray, MLXArray)]

    init(
        denoiser: StableDiffusionDenoiser, xt: MLXArray, conditioning: MLXArray,
        steps: [(MLXArray, MLXArray)],
        cfgWeight: Float, textTime: (MLXArray, MLXArray)? = nil
    ) {
        self.denoiser = denoiser
        self.steps = steps
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
        guard !Task.isCancelled, i < steps.count else {
            return nil
        }

        let (t, tPrev) = steps[i]
        i += 1

        xt = denoiser(
            xt: xt, t: t, tPrev: tPrev, conditioning: conditioning, cfgWeight: cfgWeight,
            textTime: textTime)
        return xt
    }
}

/// Type for the _decoder_ step.
public typealias ImageDecoder = (MLXArray) throws -> MLXArray

public protocol ImageGenerator {
    func ensureLoaded() throws

    /// Return a detached decoder -- this is useful if trying to conserve memory.
    ///
    /// The decoder can be used independently of the ImageGenerator to transform
    /// latents into raster images.
    func detachedDecoder() throws -> ImageDecoder

    /// the equivalent to the ``detachedDecoder()`` but without the detatching
    func decode(xt: MLXArray) throws -> MLXArray
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
    func generateLatents(parameters: StableDiffusionEvaluateParameters) throws -> DenoiseIterator
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
        throws -> DenoiseIterator
}

enum ModelContainerError: LocalizedError {
    /// Unable to create the particular type of model, e.g. it doesn't support image to image
    case unableToCreate(String, String)
    var errorDescription: String? {
        switch self {
        case .unableToCreate(let modelId, let generatorType):
            return String(
                localized:
                    "Unable to create a \(generatorType) with model ID '\(modelId)'. The model may not support this operation type."
            )
        }
    }
}

/// Container for models that guarantees single threaded access.
public actor StableDiffusionModelContainer<M> {

    let model: M

    private init(model: M) {
        self.model = model
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

    /// Perform an action on the model and/or tokenizer. Callers _must_ eval any `MLXArray` before returning as
    /// `MLXArray` is not `Sendable`.
    public func perform<R>(_ action: @Sendable (M) throws -> R) throws -> R {
        try action(model)
    }

}
