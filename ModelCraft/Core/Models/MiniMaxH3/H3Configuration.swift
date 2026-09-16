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
    ///
    /// The repository carries the same weights twice. `FL2VA/` and `Ref2VA/` hold
    /// each task's own copy of everything — transformer, video VAE, tokenizer,
    /// text encoder — while the root holds one copy of the shared components
    /// alongside the two task transformers as the **diffusers** export, and this
    /// configuration reads the latter:
    ///
    ///     transformer/       this task's DiT, 14 shards
    ///     transformer_ref/   the Ref2VA task's DiT
    ///     vae/               the video VAE, three shards, shared by both tasks
    ///
    /// Pointing the shared components at the root rather than at a task directory
    /// is what keeps the download from carrying a 66 GB text encoder twice.
    ///
    /// The two exports name the same weights differently — the task directories
    /// spell a fused `attn.qkv_proj` and `mlp.fc1`, diffusers spells
    /// `attn.to_q`/`to_k`/`to_v` and `ff.net.0.proj`/`ff.net.2` — and the layers
    /// declare the diffusers names. The loader reconciles the difference.
    public static let presetH3BaseFL2VA = H3Configuration(
        id: "MiniMaxAI/MiniMax-H3",
        task: .fl2va,
        outputWidth: 1344,
        outputHeight: 768,
        files: [
            .modelIndex: "model_index.json",
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
    ///
    /// Identical to FL2VA but for the transformer: same root tokenizer, text
    /// encoder, audio VAE and video VAE, and `transformer_ref/` in place of
    /// `transformer/`.
    public static let presetH3BaseRef2VA = H3Configuration(
        id: "MiniMaxAI/MiniMax-H3",
        task: .ref2va,
        outputWidth: 1344,
        outputHeight: 768,
        files: [
            .modelIndex: "model_index.json",
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
            H3Base(hub: hub, configuration: configuration)
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

    /// How much of one render this machine is asked to hold — the tier every
    /// component read is shaped by. See ``H3RuntimeProfile``.
    ///
    /// A device decision rather than a preset one, so it is not public and the
    /// presets neither set nor mention it: it defaults to this machine's tier and
    /// a caller that wants another (a test, a tool with its own budget) assigns a
    /// profile to its own copy of the configuration.
    var runtimeProfile = H3RuntimeProfile.deviceDefault

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

    /// How many latent values one patch carries — the patch volume, and with it
    /// the width of a packed video row.
    public var patchVolume: Int { patchSize.reduce(1, *) }
    public var textDim = 5120
    public var timestepInputDim = 256
    public var timeEmbedHidden = 5376
    public var timeEmbedDim = 2688
    public var adalnOutFeatures = 96_768
    public var finalAdalnOutFeatures = 10_752
    public var ropeInvFreqLen = 16

    /// The DiT's rotation frequencies are not in the diffusers export: the
    /// reference builds them from this and ``ropeInvFreqLen``, and so does
    /// ``H3OmniTransformer``.
    public var ropeTheta = 10_000.0
    public var normEps: Float = 1e-5
    public var qkNormEps: Float = 1e-5
    public var finalNormEps: Float = 1e-5

    // The paper-level components H3 connects. Each owns its own configuration and
    // they are all reachable from here, so one value carries everything a render
    // needs and every knob is visible in one place. They stay separate types
    // rather than being flattened: the DiT and the encoder share field names
    // (`headDim`, `numLayers`) with unrelated meanings, and a flat struct would
    // make one silently change with the other.

    /// The Qwen3-VL-32B language stack that produces text conditioning.
    ///
    /// Not public, with the three below it: these are the components' own
    /// dimensions, and each is read out of the component's file where the
    /// checkpoint states it rather than set from outside.
    var textEncoder = H3TextEncoderConfiguration()

    /// The Qwen3-VL vision tower that turns an image reference into tokens.
    var visionEncoder = H3VisionEncoderConfiguration()

    /// The video VAE, both directions. Every field here is one this checkpoint
    /// states in `vae/config.json` — see
    /// ``H3Loader/videoVAEConfiguration(at:)``, which reads them from there rather
    /// than from a table in code.
    var videoVAE = H3VideoVAEConfiguration()

    /// The audio VAE, both directions. Read from `audio_vae/config.json` the same
    /// way — see ``H3Loader/audioVAEConfiguration(at:)``.
    var audioVAE = H3AudioVAEConfiguration()

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


/// The Qwen3-VL-32B language stack, as a set of knobs.
///
/// MiniMax packages it as H3's `text_encoder` alongside the vision tower below.
/// H3 exposes the hidden state after ``numLayers``: the checkpoint carries more
/// layers than that and the rest are never evaluated. There is no final norm and
/// no lm_head in the conditioning path, and the decoder's causal mask is
/// preserved.
struct H3TextEncoderConfiguration: Sendable, Equatable {
    var hiddenSize = 5120
    var numLayers = 50
    var numHeads = 64
    /// Grouped-query attention: 64 query heads share 8 key/value heads.
    var numKVHeads = 8
    var headDim = 128
    var intermediateSize = 25600
    var vocabSize = 151_936
    var rmsNormEps: Float = 1e-6
    /// 5e6, not the 1e6 of plain Qwen3 — the VL variant widens it.
    var ropeTheta: Float = 5_000_000.0
    /// Interleaved-mRoPE band widths for t, h, w. They sum to `headDim / 2`.
    var ropeDims = [24, 20, 20]
    init() {}

    var innerDim: Int { numHeads * headDim }
    var kvDim: Int { numKVHeads * headDim }
}


/// The Qwen3-VL vision tower, as a set of knobs.
///
/// 351 of the `text_encoder` file's 902 tensors, under `visual.*`: a patch
/// embedding, a 48x48 learned position grid, 27 blocks at 1152-dim, a merger
/// that projects into the language model's 5120-dim space, and — the
/// Qwen3-VL-specific part — three **deepstack** mergers that tap layers 8, 16 and
/// 24 and inject those features back into the language stack at the image's
/// token positions.
///
/// It is reachable only through **image prompts**. It has nothing to do with I2V
/// keyframes, which go through the Visual VAE; confusing the two is easy because
/// both take an image and both feed the DiT.
struct H3VisionEncoderConfiguration: Sendable, Equatable {
    var hiddenSize = 1152
    var intermediateSize = 4304
    var depth = 27
    var numHeads = 16
    var patchSize = 16
    var temporalPatchSize = 2
    var inChannels = 3
    var spatialMergeSize = 2
    /// 2304 = 48x48. The grid is bilinearly resampled to each image's shape.
    var numPositionEmbeddings = 2304
    /// H3's language hidden size — what the merger projects into.
    var outHiddenSize = 5120
    /// Layers whose output is tapped for deepstack injection.
    var deepstackIndexes = [8, 16, 24]
    init() {}

    var headDim: Int { hiddenSize / numHeads }
    /// RoPE is applied over half the head dim, split again between row and col.
    var rotaryDim: Int { headDim / 2 }
    var gridPerSide: Int { Int(Double(numPositionEmbeddings).squareRoot()) }
    var mergeUnit: Int { spatialMergeSize * spatialMergeSize }
    var mergeDim: Int { hiddenSize * mergeUnit }
}


/// The video VAE, as the checkpoint's own `config.json` states it.
///
/// Not a set of constants to keep in sync by hand: every field is read from that
/// file by ``H3Loader/videoVAEConfiguration(at:)``, so a re-export with different
/// widths needs no code change. The names follow the file's, so the two can be
/// read side by side — `decoder_ffn_mult` is ``decoderFFNMultiplier``.
struct H3VideoVAEConfiguration: Sendable, Equatable {
    /// The encoder's width per level, and the decoder's patch grid.
    var blockOutChannels = [128, 256, 256, 512, 512, 1024]
    var layersPerBlock = 2
    var latentChannels = 24
    var normGroups = 32
    var normEps: Float = 1e-6
    var spatialDownsampleFactors = [2, 2, 2, 2, 1, 1]
    var temporalDownsampleFactors = [1, 2, 2, 1, 1, 1]
    var inChannels = 3
    var outChannels = 3
    var clipLength = 17
    var tokenDrop = 3

    /// Latent normalization, which this export keeps here rather than among the
    /// weights: one value per latent channel.
    var latentsMean: [Float] = []
    var latentsStd: [Float] = []

    var decoderLayers = 36
    var decoderAttentionHeads = 32
    var decoderAttentionHeadDim = 64
    var decoderRegisterTokens = 4
    var decoderFFNMultiplier = 4
    var decoderRopeTheta: Float = 100
    var decoderRopeDimRatio: Float = 0.75
    var decoderNormEps: Float = 1e-5

    var patchSize = 16
    var patchSizeT = 4
    init() {}

    /// The width entering each encoder level: the one above it, and the image for
    /// the first.
    var encoderInputs: [Int] { [blockOutChannels[0]] + blockOutChannels.dropLast() }
    /// The decoder's residual width, which the file states as heads × head dim.
    var decoderHidden: Int { decoderAttentionHeads * decoderAttentionHeadDim }
    /// The feed-forward's width *after* the gate, which `decoder_ffn_mult` counts
    /// against the residual; its projection emits twice this.
    var decoderFFNInner: Int { decoderHidden * decoderFFNMultiplier }
    /// `conv_out` emits a mean and a deviation for every latent channel.
    var quantChannels: Int { 2 * latentChannels }
}


/// The audio VAE, as the checkpoint's own `audio_vae/config.json` states it.
///
/// Same rule as ``H3VideoVAEConfiguration``: every field is read from that file
/// by ``H3Loader/audioVAEConfiguration(at:)``, so a re-export with different
/// widths needs no code change. The names follow the file's.
///
/// Two of these deserve a note because the weights do **not** carry them, which
/// is easy to assume they do: `latents_mean` and `latents_std` live in this file
/// and not in the safetensors, exactly as the video VAE's do.
struct H3AudioVAEConfiguration: Sendable, Equatable {
    /// The encoder's width at its narrowest, and how many times it doubles.
    var encoderDim = 64
    var encoderRates = [2, 4, 4, 5, 5]
    /// The width the encoder reaches before the pooling head, and the width the
    /// decoder's first convolution takes back. Named for what it is in the
    /// reference, not for a mel spectrogram: nothing here is a spectrogram.
    var latentDim = 2048
    var latentChannels = 32

    /// The decoder's width before its first upsample, halving at each stage.
    var decoderDim = 1024
    var decoderRates = [5, 5, 2, 2, 2, 2, 2]
    var decoderKernelSizes = [9, 9, 4, 4, 4, 4, 4]

    /// The pooling head's head count. With ``latentDim`` this fixes the head dim
    /// at 256, which is what the adaptive pool to ``latentChannels`` consumes.
    var numAttentionHeads = 8

    var resblockKernelSizes = [3, 7, 11]
    var resblockDilationSizes = [[1, 3, 5], [1, 3, 5], [1, 3, 5]]
    var samplingRate = 32_000

    /// Latent normalization, one value per latent channel, from the config file.
    var latentsMean: [Float] = []
    var latentsStd: [Float] = []

    init() {}

    /// The encoder's width entering each stage: the mono waveform, then one
    /// doubling per rate — 64, 128, 256, 512, 1024, 2048. The last is the width
    /// the pooling head reads.
    var encoderChannels: [Int] { (0 ... encoderRates.count).map { encoderDim << $0 } }
    /// The decoder's width per upsample stage — 512, 256, 128, 64, 32, 16, 8.
    var decoderChannels: [Int] { (0 ..< decoderRates.count).map { decoderDim >> ($0 + 1) } }
    /// Residual blocks stacked after each upsample stage.
    var numKernels: Int { resblockKernelSizes.count }
    /// Audio samples per latent frame — the encoder's rates multiplied out, 800.
    var hopLength: Int { encoderRates.reduce(1, *) }
}
