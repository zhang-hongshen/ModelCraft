//
//  LTXVideoConfiguration.swift
//  ModelCraft
//

import Foundation

import Hub

public enum LTXVideoFileKey: String, Sendable, Codable {
    case transformerWeights
    case textEncoderWeights
    case tokenizer
    case vaeWeights
}

public enum LTXVideoAspectRatio: String, CaseIterable, Sendable, Codable {
    case ultraWide = "21:9"
    case landscape = "16:9"
    case photoLandscape = "3:2"
    case classicLandscape = "4:3"
    case square = "1:1"
    case classicPortrait = "3:4"
    case photoPortrait = "2:3"
    case portrait = "9:16"
    case ultraTall = "9:21"

    public var value: Double {
        Double(widthUnits) / Double(heightUnits)
    }

    func dimensions(resolution: LTXVideoResolution) -> (width: Int, height: Int) {
        let scale = resolution.rawValue / max(widthUnits, heightUnits)
        return (widthUnits * scale, heightUnits * scale)
    }

    private var widthUnits: Int {
        switch self {
        case .ultraWide: 21
        case .landscape: 16
        case .photoLandscape: 3
        case .classicLandscape: 4
        case .square: 1
        case .classicPortrait: 3
        case .photoPortrait: 2
        case .portrait: 9
        case .ultraTall: 9
        }
    }

    private var heightUnits: Int {
        switch self {
        case .ultraWide: 9
        case .landscape: 9
        case .photoLandscape: 2
        case .classicLandscape: 3
        case .square: 1
        case .classicPortrait: 4
        case .photoPortrait: 3
        case .portrait: 16
        case .ultraTall: 21
        }
    }
}

public enum LTXVideoResolution: Int, CaseIterable, Sendable, Codable {
    case compact = 512
    case standard = 768
    case full = 1280

    public static func recommended(physicalMemory: UInt64) -> Self {
        let gibibyte = UInt64(1024 * 1024 * 1024)
        if physicalMemory < 32 * gibibyte { return .compact }
        if physicalMemory < 48 * gibibyte { return .standard }
        return .full
    }

    public static var deviceRecommendation: Self {
        recommended(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }
}

public enum LTXVideoProgress: Equatable, Sendable {
    case preparing
    case generating(completed: Int, total: Int)
    case decoding
    case writing
}

public typealias LTXVideoProgressHandler = @Sendable (LTXVideoProgress) async -> Void

public struct LTXVideoEvaluateParameters: Sendable {
    public var prompt: String
    public var ratio: LTXVideoAspectRatio
    public var resolution: LTXVideoResolution
    public var duration: Int

    public var width: Int { ratio.dimensions(resolution: resolution).width }
    public var height: Int { ratio.dimensions(resolution: resolution).height }

    var paddedWidth: Int { Self.padded(width, toMultipleOf: 32) }
    var paddedHeight: Int { Self.padded(height, toMultipleOf: 32) }

    static let frameRate = 24
    static let steps = 8
    static let decodeNoiseScale: Float = 0.025
    static let maxTokenCount = 128
    static let minimumDuration = 1
    static let maximumDuration = 10

    var frameCount: Int {
        let requestedFrames = duration * Self.frameRate
        return ((requestedFrames - 1 + 7) / 8) * 8 + 1
    }

    public init(
        prompt: String,
        ratio: LTXVideoAspectRatio,
        resolution: LTXVideoResolution,
        duration: Int
    ) {
        self.prompt = prompt
        self.ratio = ratio
        self.resolution = resolution
        self.duration = duration
    }

    private static func padded(_ value: Int, toMultipleOf multiple: Int) -> Int {
        ((value + multiple - 1) / multiple) * multiple
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
    private static let tokenizerRepositoryID = "Xenova/t5-tokenizer-new"

    public let id: String
    public let files: [LTXVideoFileKey: String]
    public let transformer: LTXVideoTransformerConfiguration
    public let vae: LTXVideoVAEConfiguration
    public let makeParameters:
        @Sendable (String, LTXVideoAspectRatio, LTXVideoResolution, Int) -> LTXVideoEvaluateParameters

    public func download(
        hub: HubApi = .default,
        progressHandler: @escaping (Progress) -> Void = { _ in }
    ) async throws {
        let directory = try await hub.snapshot(
            from: Hub.Repo(id: id),
            matching: [
                files[.transformerWeights]!,
                "text_encoder/*.safetensors",
                "text_encoder/*.json",
                "tokenizer/*",
                files[.vaeWeights]!,
            ],
            progressHandler: progressHandler)

        let tokenizerDirectory = try await hub.snapshot(
            from: Hub.Repo(id: Self.tokenizerRepositoryID),
            matching: ["tokenizer.json"],
            progressHandler: progressHandler)
        let tokenizerData = try Data(
            contentsOf: tokenizerDirectory.appending(component: "tokenizer.json"))
        try tokenizerData.write(
            to: directory
                .appending(component: files[.tokenizer]!)
                .appending(component: "tokenizer.json"),
            options: .atomic)
    }

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
        makeParameters: { prompt, ratio, resolution, duration in
            LTXVideoEvaluateParameters(
                prompt: prompt,
                ratio: ratio,
                resolution: resolution,
                duration: duration)
        }
    )
}
