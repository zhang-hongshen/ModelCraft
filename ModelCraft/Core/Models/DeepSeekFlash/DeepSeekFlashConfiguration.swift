//
//  DeepSeekFlashConfiguration.swift
//  ModelCraft
//
//  Created by Hongshen on 26/9/26.
//

import Foundation
import Hub

public struct DeepSeekFlashConfiguration: Decodable, Sendable {
    public static let repositoryID = "deepseek-ai/DeepSeek-V4-Flash-Vision-Exp"

    public let vocabularySize: Int
    public let hiddenSize: Int
    public let moeIntermediateSize: Int
    public let numHiddenLayers: Int
    public let numNextPredictLayers: Int
    public let numHashLayers: Int
    public let numAttentionHeads: Int
    public let numRoutedExperts: Int
    public let numSharedExperts: Int
    public let numExpertsPerToken: Int
    public let qLoraRank: Int
    public let headDimension: Int
    public let ropeHeadDimension: Int
    public let outputGroups: Int
    public let outputLoraRank: Int
    public let slidingWindow: Int
    public let rmsNormEpsilon: Float
    public let routedScalingFactor: Float
    public let swigluLimit: Float
    public let compressRopeTheta: Float
    public let compressRatios: [Int]
    public let indexHeadCount: Int
    public let indexHeadDimension: Int
    public let indexTopK: Int
    public let hyperConnectionMultiplier: Int
    public let hyperConnectionSinkhornIterations: Int
    public let hyperConnectionEpsilon: Float
    public let maxPositionEmbeddings: Int
    public let ropeTheta: Float
    public let ropeFactor: Float
    public let originalMaxPositionEmbeddings: Int
    public let ropeBetaFast: Int
    public let ropeBetaSlow: Int
    public let dsparkBlockSize: Int
    public let dsparkNoiseTokenID: Int
    public let dsparkTargetLayerIDs: [Int]
    public let dsparkMarkovRank: Int
    public let beginningOfSentenceTokenID: Int
    public let endOfSentenceTokenID: Int
    public let visionLayerCount: Int
    public let visionDimension: Int
    public let visionHeadCount: Int
    public let visionIntermediateSize: Int
    public let visionPatchSize: Int
    public let visionRopeTheta: Float
    public let visionDownsampleRatio: Int
    public let visionMaximumTokenCount: Int
    public let visionMinimumPixels: Int
    public let visionMaximumWidthHeightRatio: Int

    private enum CodingKeys: String, CodingKey {
        case vocabularySize = "vocab_size"
        case hiddenSize = "hidden_size"
        case moeIntermediateSize = "moe_intermediate_size"
        case numHiddenLayers = "num_hidden_layers"
        case numNextPredictLayers = "num_nextn_predict_layers"
        case numHashLayers = "num_hash_layers"
        case numAttentionHeads = "num_attention_heads"
        case numRoutedExperts = "n_routed_experts"
        case numSharedExperts = "n_shared_experts"
        case numExpertsPerToken = "num_experts_per_tok"
        case qLoraRank = "q_lora_rank"
        case headDimension = "head_dim"
        case ropeHeadDimension = "qk_rope_head_dim"
        case outputGroups = "o_groups"
        case outputLoraRank = "o_lora_rank"
        case slidingWindow = "sliding_window"
        case rmsNormEpsilon = "rms_norm_eps"
        case routedScalingFactor = "routed_scaling_factor"
        case swigluLimit = "swiglu_limit"
        case compressRopeTheta = "compress_rope_theta"
        case compressRatios = "compress_ratios"
        case indexHeadCount = "index_n_heads"
        case indexHeadDimension = "index_head_dim"
        case indexTopK = "index_topk"
        case hyperConnectionMultiplier = "hc_mult"
        case hyperConnectionSinkhornIterations = "hc_sinkhorn_iters"
        case hyperConnectionEpsilon = "hc_eps"
        case maxPositionEmbeddings = "max_position_embeddings"
        case ropeTheta = "rope_theta"
        case ropeScaling = "rope_scaling"
        case dsparkBlockSize = "dspark_block_size"
        case dsparkNoiseTokenID = "dspark_noise_token_id"
        case dsparkTargetLayerIDs = "dspark_target_layer_ids"
        case dsparkMarkovRank = "dspark_markov_rank"
        case beginningOfSentenceTokenID = "bos_token_id"
        case endOfSentenceTokenID = "eos_token_id"
        case visionLayerCount = "vision_n_layers"
        case visionDimension = "vision_dim"
        case visionHeadCount = "vision_n_heads"
        case visionIntermediateSize = "vision_inter_dim"
        case visionPatchSize = "vision_patch_size"
        case visionRopeTheta = "vision_rope_theta"
        case visionDownsampleRatio = "vision_downsample_ratio"
        case visionMaximumTokenCount = "vision_max_n_token"
        case visionMinimumPixels = "vision_min_pixels"
        case visionMaximumWidthHeightRatio = "vision_max_wh_ratio"
    }

    private struct RopeScaling: Decodable {
        let factor: Float
        let originalMaxPositionEmbeddings: Int
        let betaFast: Int
        let betaSlow: Int

        private enum CodingKeys: String, CodingKey {
            case factor
            case originalMaxPositionEmbeddings = "original_max_position_embeddings"
            case betaFast = "beta_fast"
            case betaSlow = "beta_slow"
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let ropeScaling = try values.decode(RopeScaling.self, forKey: .ropeScaling)
        vocabularySize = try values.decode(Int.self, forKey: .vocabularySize)
        hiddenSize = try values.decode(Int.self, forKey: .hiddenSize)
        moeIntermediateSize = try values.decode(Int.self, forKey: .moeIntermediateSize)
        numHiddenLayers = try values.decode(Int.self, forKey: .numHiddenLayers)
        numNextPredictLayers = try values.decode(Int.self, forKey: .numNextPredictLayers)
        numHashLayers = try values.decode(Int.self, forKey: .numHashLayers)
        numAttentionHeads = try values.decode(Int.self, forKey: .numAttentionHeads)
        numRoutedExperts = try values.decode(Int.self, forKey: .numRoutedExperts)
        numSharedExperts = try values.decode(Int.self, forKey: .numSharedExperts)
        numExpertsPerToken = try values.decode(Int.self, forKey: .numExpertsPerToken)
        qLoraRank = try values.decode(Int.self, forKey: .qLoraRank)
        headDimension = try values.decode(Int.self, forKey: .headDimension)
        ropeHeadDimension = try values.decode(Int.self, forKey: .ropeHeadDimension)
        outputGroups = try values.decode(Int.self, forKey: .outputGroups)
        outputLoraRank = try values.decode(Int.self, forKey: .outputLoraRank)
        slidingWindow = try values.decode(Int.self, forKey: .slidingWindow)
        rmsNormEpsilon = try values.decode(Float.self, forKey: .rmsNormEpsilon)
        routedScalingFactor = try values.decode(Float.self, forKey: .routedScalingFactor)
        swigluLimit = try values.decode(Float.self, forKey: .swigluLimit)
        compressRopeTheta = try values.decode(Float.self, forKey: .compressRopeTheta)
        compressRatios = try values.decode([Int].self, forKey: .compressRatios)
        indexHeadCount = try values.decode(Int.self, forKey: .indexHeadCount)
        indexHeadDimension = try values.decode(Int.self, forKey: .indexHeadDimension)
        indexTopK = try values.decode(Int.self, forKey: .indexTopK)
        hyperConnectionMultiplier = try values.decode(Int.self, forKey: .hyperConnectionMultiplier)
        hyperConnectionSinkhornIterations = try values.decode(
            Int.self, forKey: .hyperConnectionSinkhornIterations)
        hyperConnectionEpsilon = try values.decode(Float.self, forKey: .hyperConnectionEpsilon)
        maxPositionEmbeddings = try values.decode(Int.self, forKey: .maxPositionEmbeddings)
        ropeTheta = try values.decode(Float.self, forKey: .ropeTheta)
        ropeFactor = ropeScaling.factor
        originalMaxPositionEmbeddings = ropeScaling.originalMaxPositionEmbeddings
        ropeBetaFast = ropeScaling.betaFast
        ropeBetaSlow = ropeScaling.betaSlow
        dsparkBlockSize = try values.decode(Int.self, forKey: .dsparkBlockSize)
        dsparkNoiseTokenID = try values.decode(Int.self, forKey: .dsparkNoiseTokenID)
        dsparkTargetLayerIDs = try values.decode([Int].self, forKey: .dsparkTargetLayerIDs)
        dsparkMarkovRank = try values.decode(Int.self, forKey: .dsparkMarkovRank)
        beginningOfSentenceTokenID = try values.decode(Int.self, forKey: .beginningOfSentenceTokenID)
        endOfSentenceTokenID = try values.decode(Int.self, forKey: .endOfSentenceTokenID)
        visionLayerCount = try values.decode(Int.self, forKey: .visionLayerCount)
        visionDimension = try values.decode(Int.self, forKey: .visionDimension)
        visionHeadCount = try values.decode(Int.self, forKey: .visionHeadCount)
        visionIntermediateSize = try values.decode(Int.self, forKey: .visionIntermediateSize)
        visionPatchSize = try values.decode(Int.self, forKey: .visionPatchSize)
        visionRopeTheta = try values.decode(Float.self, forKey: .visionRopeTheta)
        visionDownsampleRatio = try values.decode(Int.self, forKey: .visionDownsampleRatio)
        visionMaximumTokenCount = try values.decode(Int.self, forKey: .visionMaximumTokenCount)
        visionMinimumPixels = try values.decode(Int.self, forKey: .visionMinimumPixels)
        visionMaximumWidthHeightRatio = try values.decode(
            Int.self, forKey: .visionMaximumWidthHeightRatio)

        guard compressRatios.count == numHiddenLayers + numNextPredictLayers else {
            throw DecodingError.dataCorruptedError(
                forKey: .compressRatios,
                in: values,
                debugDescription: "DeepSeek V4 Flash Vision Exp must include one ratio per main and MTP layer")
        }
    }

    public static func download(
        hub: HubApi = .default,
        progressHandler: @escaping (Progress) -> Void = { _ in }
    ) async throws {
        try await hub.snapshot(
            from: Hub.Repo(id: repositoryID),
            matching: [
                "config.json",
                "tokenizer.json",
                "tokenizer_config.json",
                "model.safetensors.index.json",
                "model-*.safetensors",
            ],
            progressHandler: progressHandler)
    }
}
