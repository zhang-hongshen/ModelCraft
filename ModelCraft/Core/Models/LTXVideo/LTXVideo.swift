//
//  LTXVideo.swift
//  ModelCraft
//

import Foundation

import Hub
import MLX

public final class LTXVideo {
    public let configuration: LTXVideoConfiguration
    public var transformer: LTXVideoTransformer3DModel?
    public var textEncoder: LTXVideoTextEncoder?
    public var tokenizer: LTXVideoTokenizer?
    public var vae: LTXVideoVAE?

    public init(configuration: LTXVideoConfiguration = .ltxv2BDistilled) {
        self.configuration = configuration
    }

    public func encodePrompt(_ parameters: LTXVideoEvaluateParameters) async throws -> LTXVideoPromptEncoding {
        if tokenizer == nil {
            tokenizer = LTXVideoTokenizer(tokenizer: try await LTXVideoLoader.loadTokenizer(configuration: configuration))
        }
        if textEncoder == nil {
            textEncoder = try LTXVideoLoader.loadTextEncoder(configuration: configuration)
        }
        guard let tokenizer, let textEncoder else {
            throw LTXVideoLoaderError.unsupportedWeightLayout("Unable to load LTX text encoder.")
        }

        let (ids, mask) = tokenizer.encode(parameters.prompt, maxLength: parameters.maxTokenCount)
        let embeddings = textEncoder.encode(inputIDs: ids).asType(.bfloat16)
        return LTXVideoPromptEncoding(embeddings: embeddings, attentionMask: mask)
    }

    public func generateLatents(_ parameters: LTXVideoEvaluateParameters) async throws -> MLXArray {
        let promptEncoding = try await encodePrompt(parameters)

        // Keep T5 out of memory during the DiT pass.
        textEncoder = nil
        tokenizer = nil
        Memory.clearCache()

        if transformer == nil {
            transformer = try LTXVideoLoader.loadTransformer(configuration: configuration)
        }
        guard let transformer else {
            throw LTXVideoLoaderError.unsupportedWeightLayout("Unable to load LTX transformer.")
        }

        let vaeConfig = configuration.vae
        let latentFrames = (parameters.frameCount - 1) / vaeConfig.temporalCompressionRatio + 1
        let latentHeight = parameters.height / vaeConfig.spatialCompressionRatio
        let latentWidth = parameters.width / vaeConfig.spatialCompressionRatio
        let latentShape = [
            1,
            latentFrames,
            latentHeight,
            latentWidth,
            configuration.transformer.inChannels,
        ]
        var latents = MLXRandom.normal(latentShape).asType(.float32)
        latents = LTXVideoLatentPacker.pack(
            latents,
            patchSize: configuration.transformer.patchSize,
            patchSizeT: configuration.transformer.patchSizeT
        )

        var scheduler = LTXVideoFlowMatchEulerScheduler()
        scheduler.setTimesteps(
            stepCount: parameters.steps,
            sequenceLength: latentFrames * latentHeight * latentWidth
        )

        let ropeScale = (
            Float(vaeConfig.temporalCompressionRatio) / Float(parameters.frameRate),
            Float(vaeConfig.spatialCompressionRatio),
            Float(vaeConfig.spatialCompressionRatio)
        )

        for (stepIndex, timestepValue) in scheduler.timesteps.enumerated() {
            let timestep = MLXArray([timestepValue]).asType(.float32)
            let noisePrediction = transformer(
                hiddenStates: latents.asType(.bfloat16),
                encoderHiddenStates: promptEncoding.embeddings,
                timestep: timestep,
                encoderAttentionMask: promptEncoding.attentionMask,
                frameCount: latentFrames,
                height: latentHeight,
                width: latentWidth,
                ropeInterpolationScale: ropeScale
            ).asType(.float32)
            latents = scheduler.step(modelOutput: noisePrediction, stepIndex: stepIndex, sample: latents)
            MLX.eval(latents)
        }

        return latents
    }

    public func generate(_ parameters: LTXVideoEvaluateParameters) async throws -> MLXArray {
        var latents = try await generateLatents(parameters)

        transformer = nil
        Memory.clearCache()

        if vae == nil {
            vae = try LTXVideoLoader.loadVAE(configuration: configuration)
        }
        guard let vae else {
            throw LTXVideoLoaderError.unsupportedWeightLayout("Unable to load LTX VAE.")
        }

        let vaeConfig = configuration.vae
        let latentFrames = (parameters.frameCount - 1) / vaeConfig.temporalCompressionRatio + 1
        let latentHeight = parameters.height / vaeConfig.spatialCompressionRatio
        let latentWidth = parameters.width / vaeConfig.spatialCompressionRatio

        latents = LTXVideoLatentPacker.unpack(
            latents,
            frameCount: latentFrames,
            height: latentHeight,
            width: latentWidth,
            patchSize: configuration.transformer.patchSize,
            patchSizeT: configuration.transformer.patchSizeT
        )
        latents = vae.denormalize(latents).asType(.bfloat16)

        if parameters.decodeNoiseScale > 0 {
            let noise = MLXRandom.normal(latents.shape).asType(latents.dtype)
            latents = (1 - parameters.decodeNoiseScale) * latents + parameters.decodeNoiseScale * noise
        }

        var video = vae.decode(latents)
        if Int(video.shape[1]) > parameters.frameCount {
            video = video[0..., 0..<parameters.frameCount, 0..., 0..., 0...]
        }
        return video
    }

    public func cleanup() {
        transformer = nil
        textEncoder = nil
        tokenizer = nil
        vae = nil
        Memory.clearCache()
    }
}

