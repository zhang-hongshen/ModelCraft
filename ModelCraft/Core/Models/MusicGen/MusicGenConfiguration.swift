//
//  MusicGenConfiguration.swift
//  ModelCraft
//
//  Created by Hongshen on 28/5/26.
//

import Foundation

import Hub

public struct MusicGenConfiguration: Sendable {
    
    public var id: String
    public let audioEncoderParameters: MusicGenAudioEncoderParameters
    public let textEncoderParameters: MusicGenTextEncoderParameters
    public let decoderParameters: MusicGenDecoderParameters
    public let defaultParameters: @Sendable () -> MusicGenEvaluateParameters
    
    public init(id: String, audioEncoderParameters: MusicGenAudioEncoderParameters, textEncoderParameters: MusicGenTextEncoderParameters, decoderParameters: MusicGenDecoderParameters, defaultParameters: @Sendable @escaping () -> MusicGenEvaluateParameters) {
        self.id = id
        self.audioEncoderParameters = audioEncoderParameters
        self.textEncoderParameters = textEncoderParameters
        self.decoderParameters = decoderParameters
        self.defaultParameters = defaultParameters
    }
    
    
    public func download(
        hub: HubApi = .default, progressHandler: @escaping (Progress) -> Void = { _ in }
    ) async throws {
        let repo = Hub.Repo(id: self.id)
        try await hub.snapshot(
            from: repo, matching: ["*.json", "state_dict.bin"], progressHandler: progressHandler)
        try await audioEncoderParameters.download()
        try await textEncoderParameters.download()
    }
    
    public static let small = MusicGenConfiguration(
        id: "facebook/musicgen-small",
        audioEncoderParameters: MusicGenAudioEncoderParameters(
            id: "mlx-community/encodec-32khz-float32",
            audioChannels: 1,
            chunkLengthS: nil,
            codebookDim: 128,
            codebookSize: 2048,
            compress: 2,
            dilationGrowthRate: 2,
            hiddenSize: 128,
            kernelSize: 7,
            lastKernelSize: 7,
            normalize: false,
            normType: "weight_norm",
            numFilters: 64,
            numLstmLayers: 2,
            numResidualLayers: 1,
            overlap: nil,
            padMode: .reflect,
            residualKernelSize: 3,
            samplingRate: 32000,
            targetBandwidths: [2.2],
            trimRightRatio: 1.0,
            upsamplingRatios: [8, 5, 4, 4],
            useCausalConv: false,
            useConvShortcut: false
        ),
        textEncoderParameters: MusicGenTextEncoderParameters(
            id: "google/t5-base",
            decoderStartTokenId: 0,
            dim: 768,
            dimFf: 3072,
            dimKv: 64,
            feedForwardProj: "relu",
            layerNormEpsilon: 1e-6,
            numDecoderLayers: 12,
            numHeads: 12,
            numLayers: 12,
            relativeAttentionMaxDistance: 128,
            relativeAttentionNumBuckets: 32,
            tieWordEmbeddings: true,
            vocabSize: 32128
        ),
        decoderParameters: MusicGenDecoderParameters(
            bosTokenId: 2048, ffnDim: 4096, hiddenSize: 1024, numAttentionHeads: 16, numCodebooks: 4, numHiddenLayers: 24),
        defaultParameters: { MusicGenEvaluateParameters() },
    )
    
    public static let medium = MusicGenConfiguration(
        id: "facebook/musicgen-medium",
        audioEncoderParameters: MusicGenAudioEncoderParameters(
            id: "mlx-community/encodec-32khz-float32",
            audioChannels: 1,
            chunkLengthS: nil,
            codebookDim: 128,
            codebookSize: 2048,
            compress: 2,
            dilationGrowthRate: 2,
            hiddenSize: 128,
            kernelSize: 7,
            lastKernelSize: 7,
            normalize: false,
            normType: "weight_norm",
            numFilters: 64,
            numLstmLayers: 2,
            numResidualLayers: 1,
            overlap: nil,
            padMode: .reflect,
            residualKernelSize: 3,
            samplingRate: 32000,
            targetBandwidths: [2.2],
            trimRightRatio: 1.0,
            upsamplingRatios: [8, 5, 4, 4],
            useCausalConv: false,
            useConvShortcut: false
        ),
        textEncoderParameters: MusicGenTextEncoderParameters(
            id: "google/t5-base",
            decoderStartTokenId: 0,
            dim: 768,
            dimFf: 3072,
            dimKv: 64,
            feedForwardProj: "relu",
            layerNormEpsilon: 1e-6,
            numDecoderLayers: 12,
            numHeads: 12,
            numLayers: 12,
            relativeAttentionMaxDistance: 128,
            relativeAttentionNumBuckets: 32,
            tieWordEmbeddings: true,
            vocabSize: 32128),
        decoderParameters: MusicGenDecoderParameters(
            bosTokenId: 2048, ffnDim: 6144, hiddenSize: 1536, numAttentionHeads: 24, numCodebooks: 4, numHiddenLayers: 48),
        defaultParameters: { MusicGenEvaluateParameters() },
    )
    
    public static let large = MusicGenConfiguration(
        id: "facebook/musicgen-large",
        audioEncoderParameters: MusicGenAudioEncoderParameters(
            id: "mlx-community/encodec-32khz-float32",
            audioChannels: 1,
            chunkLengthS: nil,
            codebookDim: 128,
            codebookSize: 2048,
            compress: 2,
            dilationGrowthRate: 2,
            hiddenSize: 128,
            kernelSize: 7,
            lastKernelSize: 7,
            normalize: false,
            normType: "weight_norm",
            numFilters: 64,
            numLstmLayers: 2,
            numResidualLayers: 1,
            overlap: nil,
            padMode: .reflect,
            residualKernelSize: 3,
            samplingRate: 32000,
            targetBandwidths: [2.2],
            trimRightRatio: 1.0,
            upsamplingRatios: [8, 5, 4, 4],
            useCausalConv: false,
            useConvShortcut: false
        ),
        textEncoderParameters: MusicGenTextEncoderParameters(
            id: "google/t5-base",
            decoderStartTokenId: 0,
            dim: 768,
            dimFf: 3072,
            dimKv: 64,
            feedForwardProj: "relu",
            layerNormEpsilon: 1e-6,
            numDecoderLayers: 12,
            numHeads: 12,
            numLayers: 12,
            relativeAttentionMaxDistance: 128,
            relativeAttentionNumBuckets: 32,
            tieWordEmbeddings: true,
            vocabSize: 32128),
        decoderParameters: MusicGenDecoderParameters(
            bosTokenId: 2048, ffnDim: 8192, hiddenSize: 2048, numAttentionHeads: 32, numCodebooks: 4, numHiddenLayers: 48),
        defaultParameters: { MusicGenEvaluateParameters() },
    )
}

public struct MusicGenEvaluateParameters {
    public var prompt: String = ""
    public var maxSteps: Int = 500
    public var topK: Int = 250
    public var temperature: Float = 1.0
    public var guidanceCoef: Float = 3.0
}

public enum PadMode: String, Codable, Sendable {
    case reflect, zero
}

public struct MusicGenAudioEncoderParameters: Codable, Sendable {
    public let id: String
    public let audioChannels: Int
    public let chunkLengthS: Float?
    public let codebookDim: Int
    public let codebookSize: Int
    public let compress: Int
    public let dilationGrowthRate: Int
    public let hiddenSize: Int
    public let kernelSize: Int
    public let lastKernelSize: Int
    public let normalize: Bool
    public let normType: String
    public let numFilters: Int
    public let numLstmLayers: Int
    public let numResidualLayers: Int
    public let overlap: Float?
    public let padMode: PadMode
    public let residualKernelSize: Int
    public let samplingRate: Int
    public let targetBandwidths: [Float]
    public let trimRightRatio: Float?
    public let upsamplingRatios: [Int]
    public let useCausalConv: Bool
    public let useConvShortcut: Bool?
    
    public func download(
        hub: HubApi = .default, progressHandler: @escaping (Progress) -> Void = { _ in }
    ) async throws {
        let repo = Hub.Repo(id: self.id)
        try await hub.snapshot(
            from: repo, matching: ["*.json", "*.safetensors", "*.model"], progressHandler: progressHandler)
    }
}

public struct MusicGenTextEncoderParameters: Codable, Sendable {
    public let id: String
    public let decoderStartTokenId: Int
    public let dim: Int
    public let dimFf: Int
    public let dimKv: Int
    public let feedForwardProj: String?
    public let layerNormEpsilon: Float
    public let numDecoderLayers: Int
    public let numHeads: Int
    public let numLayers: Int
    public let relativeAttentionMaxDistance: Int
    public let relativeAttentionNumBuckets: Int
    public let tieWordEmbeddings: Bool
    public let vocabSize: Int
    
    public func download(
        hub: HubApi = .default, progressHandler: @escaping (Progress) -> Void = { _ in }
    ) async throws {
        let repo = Hub.Repo(id: self.id)
        try await hub.snapshot(
            from: repo, matching: ["*.json", "*.safetensors", "*.model"], progressHandler: progressHandler)
    }
    
}

public struct MusicGenDecoderParameters: Codable, Sendable {
    public let bosTokenId: Int
    public let ffnDim: Int
    public let hiddenSize: Int
    public let numAttentionHeads: Int
    public let numCodebooks: Int
    public let numHiddenLayers: Int
}




