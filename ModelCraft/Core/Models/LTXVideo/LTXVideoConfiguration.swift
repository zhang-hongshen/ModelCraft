//
//  LTXVideoConfiguration.swift
//  ModelCraft
//

import Foundation

public enum LTXVideoFileKey: String, Sendable, Codable {
    case transformerWeights
    case textEncoderWeights
    case tokenizer
    case vaeWeights
}

public struct LTXVideoEvaluateParameters: Sendable {
    public var prompt: String
    public var negativePrompt: String
    public var width: Int
    public var height: Int
    public var frameCount: Int
    public var frameRate: Int
    public var steps: Int
    public var guidanceScale: Float
    public var decodeTimestep: Float
    public var decodeNoiseScale: Float
    public var maxTokenCount: Int

    public init(
        prompt: String,
        negativePrompt: String = "worst quality, inconsistent motion, blurry, jittery, distorted",
        width: Int = 512,
        height: Int = 320,
        frameCount: Int = 33,
        frameRate: Int = 24,
        steps: Int = 8,
        guidanceScale: Float = 1.0,
        decodeTimestep: Float = 0.05,
        decodeNoiseScale: Float = 0.025,
        maxTokenCount: Int = 128
    ) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.frameRate = frameRate
        self.steps = steps
        self.guidanceScale = guidanceScale
        self.decodeTimestep = decodeTimestep
        self.decodeNoiseScale = decodeNoiseScale
        self.maxTokenCount = maxTokenCount
    }
}

public struct LTXVideoTransformerConfiguration: Sendable, Codable {
    public let inChannels: Int
    public let outChannels: Int
    public let patchSize: Int
    public let patchSizeT: Int
    public let numAttentionHeads: Int
    public let attentionHeadDim: Int
    public let crossAttentionDim: Int
    public let numLayers: Int
    public let captionChannels: Int

    public static let ltx2B = LTXVideoTransformerConfiguration(
        inChannels: 128,
        outChannels: 128,
        patchSize: 1,
        patchSizeT: 1,
        numAttentionHeads: 32,
        attentionHeadDim: 64,
        crossAttentionDim: 2048,
        numLayers: 28,
        captionChannels: 4096
    )
}

public struct LTXVideoVAEConfiguration: Sendable, Codable {
    public let latentChannels: Int
    public let blockOutChannels: [Int]
    public let layersPerBlock: [Int]
    public let spatioTemporalScaling: [Bool]
    public let patchSize: Int
    public let patchSizeT: Int
    public let spatialCompressionRatio: Int
    public let temporalCompressionRatio: Int
    public let scalingFactor: Float

    public static let ltx = LTXVideoVAEConfiguration(
        latentChannels: 128,
        blockOutChannels: [128, 256, 512, 512],
        layersPerBlock: [4, 3, 3, 3, 4],
        spatioTemporalScaling: [true, true, true, false],
        patchSize: 4,
        patchSizeT: 1,
        spatialCompressionRatio: 32,
        temporalCompressionRatio: 8,
        scalingFactor: 1.0
    )
}

public struct LTXVideoConfiguration: Sendable {
    public let id: String
    public let files: [LTXVideoFileKey: String]
    public let transformer: LTXVideoTransformerConfiguration
    public let vae: LTXVideoVAEConfiguration
    public let defaultParameters: @Sendable (_ prompt: String) -> LTXVideoEvaluateParameters

    public static let ltxv2BDistilled = LTXVideoConfiguration(
        id: "Lightricks/LTX-Video",
        files: [
            .transformerWeights: "ltxv-2b-0.9.8-distilled.safetensors",
            .textEncoderWeights: "text_encoder/model.safetensors.index.json",
            .tokenizer: "tokenizer",
            .vaeWeights: "vae/diffusion_pytorch_model.safetensors",
        ],
        transformer: .ltx2B,
        vae: .ltx,
        defaultParameters: { prompt in
            LTXVideoEvaluateParameters(prompt: prompt)
        }
    )
}

