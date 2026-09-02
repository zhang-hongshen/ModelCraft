//
//  H3Configuration.swift
//  ModelCraft
//
//  Created by Hongshen on 27/8/26.
//


import Foundation
import Hub

/// Default generation values shared by the two H3 Base presets.
public struct H3GenerationParameters: Sendable {
    public var durationSeconds: Int
    public var steps: Int
    public var seed: UInt64?

    public init(
        durationSeconds: Int = 5,
        steps: Int = 20,
        seed: UInt64? = nil
    ) {
        self.durationSeconds = durationSeconds
        self.steps = steps
        self.seed = seed
    }
}

/// File types used by ``H3Configuration/files``.
///
/// These keys describe the stable files in the official H3 repository. Keeping
/// them typed prevents a misspelled string from silently selecting the wrong
/// component while preserving the configuration-driven loading design used by
/// Stable Diffusion.
public enum H3FileKey: String, CaseIterable, Codable, Hashable, Sendable {
    case modelIndex
    case processor
    case tokenizerFiles
    case tokenizerVocabulary
    case tokenizerMerges
    case tokenizerConfig
    case textEncoderConfig
    case textEncoderWeights
    case textEncoderShards
    case transformerConfig
    case transformerWeights
    case transformerShards
    case videoVAEConfig
    case videoVAEWeights
    case videoVAEShards
    case audioVAEConfig
    case audioVAEWeights
}

/// Configuration for one MiniMax H3 Base task checkpoint.
///
/// Like ``StableDiffusionConfiguration``, this value owns the Hugging Face
/// repository id, the exact files needed by the model, default parameters and
/// the factory that constructs the selected model. The file dictionary uses
/// typed ``H3FileKey`` values: the public repository layout is fixed and the
/// concrete H3 modules can resolve the key they need without a second
/// model-root abstraction.
public struct H3Configuration: Sendable {
    public enum Task: String, Codable, Hashable, Sendable {
        case fl2va = "FL2VA"
        case ref2va = "Ref2VA"
    }

    public enum Preset: String, Codable, CaseIterable, Sendable {
        case h3BaseFL2VA = "H3-Base-FL2VA"
        case h3BaseRef2VA = "H3-Base-Ref2VA"

        public var configuration: H3Configuration {
            switch self {
            case .h3BaseFL2VA: H3Configuration.presetH3BaseFL2VA
            case .h3BaseRef2VA: H3Configuration.presetH3BaseRef2VA
            }
        }
    }

    public let id: String
    public let task: Task
    /// The dimensions produced by this checkpoint. H3 Base currently supports
    /// one fixed 768P canvas (1344x768); a future checkpoint can provide its
    /// own dimensions through a separate configuration preset.
    public let outputWidth: Int
    public let outputHeight: Int
    public let files: [H3FileKey: String]
    public let defaultParameters: @Sendable () -> H3GenerationParameters

    /// Internal for the same reason Stable Diffusion keeps its factory
    /// internal: callers select a preset, while the preset owns construction.
    let factory: @Sendable (HubApi, H3Configuration) throws -> H3Base

    /// H3-Base-FL2VA: text-to-video plus first/last-frame conditioning.
    /// The repository keeps the tokenizer, encoders and VAEs at its root; only
    /// the task manifest and FL2VA Transformer are selected here.
    public static let presetH3BaseFL2VA = H3Configuration(
        id: "MiniMaxAI/MiniMax-H3",
        task: .fl2va,
        outputWidth: 1344,
        outputHeight: 768,
        files: [
            .modelIndex: "FL2VA/model_index.json",
            .processor: "processor/*",
            .tokenizerFiles: "tokenizer/*",
            .tokenizerVocabulary: "tokenizer/vocab.json",
            .tokenizerMerges: "tokenizer/merges.txt",
            .tokenizerConfig: "tokenizer/tokenizer_config.json",
            .textEncoderConfig: "text_encoder/config.json",
            .textEncoderWeights: "text_encoder/model.safetensors.index.json",
            .textEncoderShards: "text_encoder/model-*.safetensors",
            .transformerConfig: "transformer/config.json",
            .transformerWeights: "transformer/diffusion_pytorch_model.safetensors.index.json",
            .transformerShards: "transformer/diffusion_pytorch_model-*.safetensors",
            .videoVAEConfig: "vae/config.json",
            .videoVAEWeights: "vae/diffusion_pytorch_model.safetensors.index.json",
            .videoVAEShards: "vae/diffusion_pytorch_model-*.safetensors",
            .audioVAEConfig: "audio_vae/config.json",
            .audioVAEWeights: "audio_vae/diffusion_pytorch_model.safetensors",
        ],
        defaultParameters: { H3GenerationParameters() }
    )

    /// H3-Base-Ref2VA: ordered image/video/audio reference conditioning.
    /// This shares the root components with FL2VA and selects `transformer_ref`.
    public static let presetH3BaseRef2VA = H3Configuration(
        id: "MiniMaxAI/MiniMax-H3",
        task: .ref2va,
        outputWidth: 1344,
        outputHeight: 768,
        files: [
            .modelIndex: "Ref2VA/model_index.json",
            .processor: "processor/*",
            .tokenizerFiles: "tokenizer/*",
            .tokenizerVocabulary: "tokenizer/vocab.json",
            .tokenizerMerges: "tokenizer/merges.txt",
            .tokenizerConfig: "tokenizer/tokenizer_config.json",
            .textEncoderConfig: "text_encoder/config.json",
            .textEncoderWeights: "text_encoder/model.safetensors.index.json",
            .textEncoderShards: "text_encoder/model-*.safetensors",
            .transformerConfig: "transformer_ref/config.json",
            .transformerWeights: "transformer_ref/diffusion_pytorch_model.safetensors.index.json",
            .transformerShards: "transformer_ref/diffusion_pytorch_model-*.safetensors",
            .videoVAEConfig: "vae/config.json",
            .videoVAEWeights: "vae/diffusion_pytorch_model.safetensors.index.json",
            .videoVAEShards: "vae/diffusion_pytorch_model-*.safetensors",
            .audioVAEConfig: "audio_vae/config.json",
            .audioVAEWeights: "audio_vae/diffusion_pytorch_model.safetensors",
        ],
        defaultParameters: { H3GenerationParameters() })

    public init(
        id: String,
        task: Task = .fl2va,
        outputWidth: Int = 1344,
        outputHeight: Int = 768,
        files: [H3FileKey: String] = [:],
        defaultParameters: @escaping @Sendable () -> H3GenerationParameters = {
            H3GenerationParameters()
        },
        factory: @escaping @Sendable (HubApi, H3Configuration) throws -> H3Base = {
            hub, configuration in
            try H3Base(hub: hub, configuration: configuration)
        }
    ) {
        self.id = id
        self.task = task
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.files = files
        self.defaultParameters = defaultParameters
        self.factory = factory
    }

    /// Downloads the selected configuration through HubApi.
    ///
    /// HubApi checks its materialized local snapshot and downloads only files
    /// not already present. No model root or local repository path is passed
    /// through the H3 API.
    public func download(
        hub: HubApi = .default,
        progressHandler: @escaping (Progress) -> Void = { _ in }
    ) async throws {
        try await hub.snapshot(
            from: Hub.Repo(id: id),
            matching: Array(files.values),
            progressHandler: progressHandler)
    }

    public var modelName: String {
        "H3-Base-\(task.rawValue)"
    }

    // H3 Omni Transformer configuration.
    public var hiddenSize = 5376
    public var numLayers = 50
    public var tokenRefinerLayers = 2
    public var numHeads = 56
    public var headDim = 128
    public var ffnHidden = 14_336
    public var videoLatentDim = 24
    public var audioLatentDim = 32
    public var patchSize = [1, 2, 2]
    public var textDim = 5120
    public var timestepInputDim = 256
    public var timeEmbedHidden = 5376
    public var timeEmbedDim = 2688
    public var adalnOutFeatures = 96_768
    public var finalAdalnOutFeatures = 10_752
    public var ropeInvFreqLen = 16
    public var normEps: Float = 1e-5
    public var qkNormEps: Float = 1e-5
    public var finalNormEps: Float = 1e-5

    // H3 output and latent geometry.
    public let frameRate = 24
    public let audioSampleRate = 32_000
    public let audioLatentFrameRate = 40
    public let visualSpatialCompression = 16
    public let visualTemporalCompression = 4
    public let frameLattice = 17
    public let frameLatticeOffset = 5
    public let minimumFrameCount = 124
    public let maximumFrameCount = 362
    public let videoSigmaShift: Double = 12.0
    public let audioSigmaShift: Double = 3.0
    public let visualConditionNoise: Float = 0.999
    public let audioConditionNoise: Float = 1.0
}
