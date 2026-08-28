// SPDX-License-Identifier: Apache-2.0

import Foundation
import Hub

/// Default generation values shared by the two H3 Base presets.
public struct H3GenerationParameters: Sendable {
    public var durationSeconds: Int
    public var width: Int
    public var height: Int
    public var steps: Int
    public var seed: UInt64

    public init(
        durationSeconds: Int = 5,
        width: Int = 1344,
        height: Int = 768,
        steps: Int = 20,
        seed: UInt64 = 0
    ) {
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.steps = steps
        self.seed = seed
    }
}

/// Configuration for one MiniMax H3 Base task checkpoint.
///
/// Like ``StableDiffusionConfiguration``, this value owns the Hugging Face
/// repository id, the exact files needed by the model, default parameters and
/// the factory that constructs the selected model. The file dictionary uses
/// stable string keys deliberately: the public repository layout is fixed and
/// the concrete H3 modules can resolve the key they need without a second
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
    public let files: [String: String]
    public let defaultParameters: @Sendable () -> H3GenerationParameters

    /// Internal for the same reason Stable Diffusion keeps its factory
    /// internal: callers select a preset, while the preset owns construction.
    let factory: @Sendable (HubApi, H3Configuration) throws -> H3BaseModel

    /// H3-Base-FL2VA: text-to-video plus first/last-frame conditioning.
    public static let presetH3BaseFL2VA = H3Configuration(
        id: "MiniMaxAI/MiniMax-H3",
        task: .fl2va,
        files: [
            "modelIndex": "FL2VA/model_index.json",
            "processor": "FL2VA/processor/*",
            "tokenizerFiles": "FL2VA/tokenizer/*",
            "tokenizerVocabulary": "FL2VA/tokenizer/vocab.json",
            "tokenizerMerges": "FL2VA/tokenizer/merges.txt",
            "tokenizerConfig": "FL2VA/tokenizer/tokenizer_config.json",
            "textEncoderConfig": "FL2VA/text_encoder/config.json",
            "textEncoderWeights": "FL2VA/text_encoder/model.safetensors.index.json",
            "textEncoderShards": "FL2VA/text_encoder/model-*.safetensors",
            "transformerConfig": "FL2VA/transformer/config.json",
            "transformerWeights": "FL2VA/transformer/model.safetensors.index.json",
            "transformerShards": "FL2VA/transformer/model-*.safetensors",
            "videoVAEConfig": "FL2VA/video_vae/source/config.json",
            "videoVAEWeights": "FL2VA/video_vae/source/model.safetensors",
            "audioVAEConfig": "FL2VA/audio_vae/config.json",
            "audioVAEWeights": "FL2VA/audio_vae/model.safetensors",
        ],
        defaultParameters: { H3GenerationParameters() },
        factory: { hub, configuration in
            H3BaseModel(hub: hub, configuration: configuration)
        })

    /// H3-Base-Ref2VA: ordered image/video/audio reference conditioning.
    public static let presetH3BaseRef2VA = H3Configuration(
        id: "MiniMaxAI/MiniMax-H3",
        task: .ref2va,
        files: [
            "modelIndex": "Ref2VA/model_index.json",
            "processor": "Ref2VA/processor/*",
            "tokenizerFiles": "Ref2VA/tokenizer/*",
            "tokenizerVocabulary": "Ref2VA/tokenizer/vocab.json",
            "tokenizerMerges": "Ref2VA/tokenizer/merges.txt",
            "tokenizerConfig": "Ref2VA/tokenizer/tokenizer_config.json",
            "textEncoderConfig": "Ref2VA/text_encoder/config.json",
            "textEncoderWeights": "Ref2VA/text_encoder/model.safetensors.index.json",
            "textEncoderShards": "Ref2VA/text_encoder/model-*.safetensors",
            "transformerConfig": "Ref2VA/transformer/config.json",
            "transformerWeights": "Ref2VA/transformer/model.safetensors.index.json",
            "transformerShards": "Ref2VA/transformer/model-*.safetensors",
            "videoVAEConfig": "Ref2VA/video_vae/source/config.json",
            "videoVAEWeights": "Ref2VA/video_vae/source/model.safetensors",
            "audioVAEConfig": "Ref2VA/audio_vae/config.json",
            "audioVAEWeights": "Ref2VA/audio_vae/model.safetensors",
        ],
        defaultParameters: { H3GenerationParameters() },
        factory: { hub, configuration in
            H3BaseModel(hub: hub, configuration: configuration)
        })

    public init(
        id: String = "MiniMaxAI/MiniMax-H3",
        task: Task = .fl2va,
        files: [String: String] = [:],
        defaultParameters: @escaping @Sendable () -> H3GenerationParameters = {
            H3GenerationParameters()
        },
        factory: @escaping @Sendable (HubApi, H3Configuration) throws -> H3BaseModel = {
            hub, configuration in
            H3BaseModel(hub: hub, configuration: configuration)
        }
    ) {
        self.id = id
        self.task = task
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

    func makeModel(hub: HubApi) throws -> H3BaseModel {
        try factory(hub, self)
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
