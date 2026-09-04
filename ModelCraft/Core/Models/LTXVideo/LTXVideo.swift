//
//  LTXVideo.swift
//  ModelCraft
//

import Foundation

import Hub
import MLX

public final class LTXVideo {
    public let configuration: LTXVideoConfiguration
    let runtimeProfile: LTXVideoRuntimeProfile
    public var transformer: LTXVideoTransformer3DModel?
    public var textEncoder: LTXVideoTextEncoder?
    public var tokenizer: LTXVideoTokenizer?
    public var vae: LTXVideoVAE?

    public convenience init(configuration: LTXVideoConfiguration = .ltxv2BDistilled) {
        self.init(configuration: configuration, runtimeProfile: .deviceDefault)
    }

    init(configuration: LTXVideoConfiguration, runtimeProfile: LTXVideoRuntimeProfile) {
        self.configuration = configuration
        self.runtimeProfile = runtimeProfile
    }

    public func encodePrompt(_ parameters: LTXVideoEvaluateParameters) async throws -> LTXVideoPromptEncoding {
        if tokenizer == nil {
            tokenizer = LTXVideoTokenizer(tokenizer: try await LTXVideoLoader.loadTokenizer(configuration: configuration))
        }
        if textEncoder == nil {
            textEncoder = try LTXVideoLoader.loadTextEncoder(
                configuration: configuration,
                quantization: runtimeProfile.textEncoderQuantization)
        }
        guard let tokenizer, let textEncoder else {
            throw LTXVideoLoaderError.unsupportedWeightLayout("Unable to load LTX text encoder.")
        }

        let (ids, mask) = tokenizer.encode(
            parameters.prompt,
            maxLength: LTXVideoEvaluateParameters.maxTokenCount)
        let embeddings = textEncoder.encode(inputIDs: ids).asType(.bfloat16)
        MLX.eval(embeddings)
        return LTXVideoPromptEncoding(embeddings: embeddings, attentionMask: mask)
    }

    public func generateLatents(
        _ parameters: LTXVideoEvaluateParameters,
        progress: LTXVideoProgressHandler = { _ in }
    ) async throws -> MLXArray {
        let promptEncoding = try await encodePrompt(parameters)

        if runtimeProfile.releasesComponentsBetweenStages {
            textEncoder = nil
            tokenizer = nil
            Memory.clearCache()
        }

        if transformer == nil {
            transformer = try LTXVideoLoader.loadTransformer(
                configuration: configuration,
                quantization: runtimeProfile.transformerQuantization)
        }
        guard let transformer else {
            throw LTXVideoLoaderError.unsupportedWeightLayout("Unable to load LTX transformer.")
        }

        let vaeConfig = configuration.vae
        let latentFrames =
            (parameters.frameCount - 1) / vaeConfig.temporalCompressionRatio + 1
        let latentHeight = parameters.paddedHeight / vaeConfig.spatialCompressionRatio
        let latentWidth = parameters.paddedWidth / vaeConfig.spatialCompressionRatio
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
            stepCount: LTXVideoEvaluateParameters.steps,
            sequenceLength: latentFrames * latentHeight * latentWidth
        )

        let ropeScale = (
            Float(vaeConfig.temporalCompressionRatio) / Float(LTXVideoEvaluateParameters.frameRate),
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
            await progress(.generating(
                completed: stepIndex + 1,
                total: scheduler.timesteps.count))
        }

        return latents
    }

    public func generate(
        _ parameters: LTXVideoEvaluateParameters,
        progress: LTXVideoProgressHandler = { _ in }
    ) async throws -> MLXArray {
        var latents = try await generateLatents(parameters, progress: progress)
        await progress(.decoding)

        if runtimeProfile.releasesComponentsBetweenStages {
            transformer = nil
            Memory.clearCache()
        }

        if vae == nil {
            vae = try LTXVideoLoader.loadVAE(configuration: configuration)
        }
        guard let vae else {
            throw LTXVideoLoaderError.unsupportedWeightLayout("Unable to load LTX VAE.")
        }

        let vaeConfig = configuration.vae
        let latentFrames =
            (parameters.frameCount - 1) / vaeConfig.temporalCompressionRatio + 1
        let latentHeight = parameters.paddedHeight / vaeConfig.spatialCompressionRatio
        let latentWidth = parameters.paddedWidth / vaeConfig.spatialCompressionRatio

        latents = LTXVideoLatentPacker.unpack(
            latents,
            frameCount: latentFrames,
            height: latentHeight,
            width: latentWidth,
            patchSize: configuration.transformer.patchSize,
            patchSizeT: configuration.transformer.patchSizeT
        )
        latents = vae.denormalize(latents).asType(.bfloat16)

        if LTXVideoEvaluateParameters.decodeNoiseScale > 0 {
            let noise = MLXRandom.normal(latents.shape).asType(latents.dtype)
            let noiseScale = LTXVideoEvaluateParameters.decodeNoiseScale
            latents = (1 - noiseScale) * latents + noiseScale * noise
        }

        var video = vae.decode(latents, tiling: runtimeProfile.decodeTiling)
        if Int(video.shape[1]) > parameters.frameCount
            || Int(video.shape[2]) > parameters.height
            || Int(video.shape[3]) > parameters.width
        {
            video = video[
                0...,
                0..<parameters.frameCount,
                0..<parameters.height,
                0..<parameters.width,
                0...
            ]
        }
        MLX.eval(video)
        if runtimeProfile.releasesComponentsBetweenStages {
            self.vae = nil
            Memory.clearCache()
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
