// Copyright © 2024 Apple Inc.

import Foundation
import Hub
import MLX
import MLXNN

// port of https://github.com/ml-explore/mlx-examples/blob/main/stable_diffusion/stable_diffusion/config.py

/// Configuration for ``Autoencoder``
struct AutoencoderConfiguration: Codable {

    public var inputChannels = 3
    public var outputChannels = 3
    public var latentChannelsOut: Int { latentChannelsIn * 2 }
    public var latentChannelsIn = 4
    public var blockOutChannels = [128, 256, 512, 512]
    public var layersPerBlock = 2
    public var normNumGroups = 32
    public var scalingFactor: Float = 0.18215

    enum CodingKeys: String, CodingKey {
        case inputChannels = "in_channels"
        case outputChannels = "out_channels"
        case latentChannelsIn = "latent_channels"
        case blockOutChannels = "block_out_channels"
        case layersPerBlock = "layers_per_block"
        case normNumGroups = "norm_num_groups"
        case scalingFactor = "scaling_factor"
    }

    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<AutoencoderConfiguration.CodingKeys> =
            try decoder.container(keyedBy: AutoencoderConfiguration.CodingKeys.self)

        // load_autoencoder()

        self.scalingFactor =
            try container.decodeIfPresent(Float.self, forKey: .scalingFactor) ?? 0.18215

        self.inputChannels = try container.decode(Int.self, forKey: .inputChannels)
        self.outputChannels = try container.decode(Int.self, forKey: .outputChannels)
        self.latentChannelsIn = try container.decode(Int.self, forKey: .latentChannelsIn)
        self.blockOutChannels = try container.decode([Int].self, forKey: .blockOutChannels)
        self.layersPerBlock = try container.decode(Int.self, forKey: .layersPerBlock)
        self.normNumGroups = try container.decode(Int.self, forKey: .normNumGroups)
    }

    public func encode(to encoder: any Encoder) throws {
        var container: KeyedEncodingContainer<AutoencoderConfiguration.CodingKeys> =
            encoder.container(keyedBy: AutoencoderConfiguration.CodingKeys.self)

        try container.encode(self.inputChannels, forKey: .inputChannels)
        try container.encode(self.outputChannels, forKey: .outputChannels)
        try container.encode(self.latentChannelsIn, forKey: .latentChannelsIn)
        try container.encode(self.blockOutChannels, forKey: .blockOutChannels)
        try container.encode(self.layersPerBlock, forKey: .layersPerBlock)
        try container.encode(self.normNumGroups, forKey: .normNumGroups)
        try container.encode(self.scalingFactor, forKey: .scalingFactor)
    }
}

/// Configuration for ``CLIPTextModel``
struct CLIPTextModelConfiguration: Codable {

    public enum ClipActivation: String, Codable {
        case fast = "quick_gelu"
        case gelu = "gelu"

        var activation: (MLXArray) -> MLXArray {
            switch self {
            case .fast: MLXNN.geluFastApproximate
            case .gelu: MLXNN.gelu
            }
        }
    }

    public var numLayers = 23
    public var modelDimensions = 1024
    public var numHeads = 16
    public var maxLength = 77
    public var vocabularySize = 49408
    public var projectionDimensions: Int? = nil
    public var hiddenActivation: ClipActivation = .fast

    enum CodingKeys: String, CodingKey {
        case numLayers = "num_hidden_layers"
        case modelDimensions = "hidden_size"
        case numHeads = "num_attention_heads"
        case maxLength = "max_position_embeddings"
        case vocabularySize = "vocab_size"
        case projectionDimensions = "projection_dim"
        case hiddenActivation = "hidden_act"
        case architectures = "architectures"
    }

    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CLIPTextModelConfiguration.CodingKeys> =
            try decoder.container(keyedBy: CLIPTextModelConfiguration.CodingKeys.self)

        // see load_text_encoder

        let architectures = try container.decode([String].self, forKey: .architectures)
        let withProjection = architectures[0].contains("WithProjection")

        self.projectionDimensions =
            withProjection
            ? try container.decodeIfPresent(Int.self, forKey: .projectionDimensions) : nil
        self.hiddenActivation =
            try container.decodeIfPresent(
                CLIPTextModelConfiguration.ClipActivation.self, forKey: .hiddenActivation) ?? .fast

        self.numLayers = try container.decode(Int.self, forKey: .numLayers)
        self.modelDimensions = try container.decode(Int.self, forKey: .modelDimensions)
        self.numHeads = try container.decode(Int.self, forKey: .numHeads)
        self.maxLength = try container.decode(Int.self, forKey: .maxLength)
        self.vocabularySize = try container.decode(Int.self, forKey: .vocabularySize)
    }

    public func encode(to encoder: any Encoder) throws {
        var container: KeyedEncodingContainer<CLIPTextModelConfiguration.CodingKeys> =
            encoder.container(keyedBy: CLIPTextModelConfiguration.CodingKeys.self)

        if projectionDimensions != nil {
            try container.encode(["WithProjection"], forKey: .architectures)
        } else {
            try container.encode(["Other"], forKey: .architectures)
        }

        try container.encode(self.numLayers, forKey: .numLayers)
        try container.encode(self.modelDimensions, forKey: .modelDimensions)
        try container.encode(self.numHeads, forKey: .numHeads)
        try container.encode(self.maxLength, forKey: .maxLength)
        try container.encode(self.vocabularySize, forKey: .vocabularySize)
        try container.encodeIfPresent(self.projectionDimensions, forKey: .projectionDimensions)
        try container.encode(self.hiddenActivation, forKey: .hiddenActivation)
    }
}

/// Configuration for ``UNetModel``
struct UNetConfiguration: Codable {

    public var inputChannels = 4
    public var outputChannels = 4
    public var convolutionInKernel = 3
    public var convolutionOutKernel = 3
    public var blockOutChannels = [320, 640, 1280, 1280]
    public var layersPerBlock = [2, 2, 2, 2]
    public var midBlockLayers = 2
    public var transformerLayersPerBlock = [2, 2, 2, 2]
    public var numHeads = [5, 10, 20, 20]
    public var crossAttentionDimension = [1024, 1024, 1024, 1024]
    public var normNumGroups = 32
    public var downBlockTypes: [String] = []
    public var upBlockTypes: [String] = []
    public var additionEmbedType: String? = nil
    public var additionTimeEmbedDimension: Int? = nil
    public var projectionClassEmbeddingsInputDimension: Int? = nil

    enum CodingKeys: String, CodingKey {
        case inputChannels = "in_channels"
        case outputChannels = "out_channels"
        case convolutionInKernel = "conv_in_kernel"
        case convolutionOutKernel = "conv_out_kernel"
        case blockOutChannels = "block_out_channels"
        case layersPerBlock = "layers_per_block"
        case midBlockLayers = "mid_block_layers"
        case transformerLayersPerBlock = "transformer_layers_per_block"
        case numHeads = "attention_head_dim"
        case crossAttentionDimension = "cross_attention_dim"
        case normNumGroups = "norm_num_groups"
        case downBlockTypes = "down_block_types"
        case upBlockTypes = "up_block_types"
        case additionEmbedType = "addition_embed_type"
        case additionTimeEmbedDimension = "addition_time_embed_dim"
        case projectionClassEmbeddingsInputDimension = "projection_class_embeddings_input_dim"
    }

    public init() {
    }

    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<UNetConfiguration.CodingKeys> = try decoder.container(
            keyedBy: UNetConfiguration.CodingKeys.self)

        // customizations based on def load_unet(key: str = _DEFAULT_MODEL, float16: bool = False):
        //
        // Note: the encode() writes out the internal format (and this can load it back in)

        self.blockOutChannels = try container.decode([Int].self, forKey: .blockOutChannels)
        let nBlocks = blockOutChannels.count

        self.layersPerBlock =
            try (try? container.decode([Int].self, forKey: .layersPerBlock))
            ?? Array(repeating: container.decode(Int.self, forKey: .layersPerBlock), count: nBlocks)
        self.transformerLayersPerBlock =
            (try? container.decode([Int].self, forKey: .transformerLayersPerBlock)) ?? [1, 1, 1, 1]
        self.numHeads =
            try (try? container.decodeIfPresent([Int].self, forKey: .numHeads))
            ?? Array(repeating: container.decode(Int.self, forKey: .numHeads), count: nBlocks)
        self.crossAttentionDimension =
            try (try? container.decode([Int].self, forKey: .crossAttentionDimension))
            ?? Array(
                repeating: container.decode(Int.self, forKey: .crossAttentionDimension),
                count: nBlocks)
        self.upBlockTypes = try container.decode([String].self, forKey: .upBlockTypes).reversed()

        self.convolutionInKernel =
            try container.decodeIfPresent(Int.self, forKey: .convolutionInKernel) ?? 3
        self.convolutionOutKernel =
            try container.decodeIfPresent(Int.self, forKey: .convolutionOutKernel) ?? 3
        self.midBlockLayers = try container.decodeIfPresent(Int.self, forKey: .midBlockLayers) ?? 2

        self.inputChannels = try container.decode(Int.self, forKey: .inputChannels)
        self.outputChannels = try container.decode(Int.self, forKey: .outputChannels)
        self.normNumGroups = try container.decode(Int.self, forKey: .normNumGroups)
        self.downBlockTypes = try container.decode([String].self, forKey: .downBlockTypes)
        self.additionEmbedType = try container.decodeIfPresent(
            String.self, forKey: .additionEmbedType)
        self.additionTimeEmbedDimension = try container.decodeIfPresent(
            Int.self, forKey: .additionTimeEmbedDimension)
        self.projectionClassEmbeddingsInputDimension = try container.decodeIfPresent(
            Int.self, forKey: .projectionClassEmbeddingsInputDimension)
    }

    public func encode(to encoder: Encoder) throws {
        var container: KeyedEncodingContainer<UNetConfiguration.CodingKeys> = encoder.container(
            keyedBy: UNetConfiguration.CodingKeys.self)

        try container.encode(self.upBlockTypes.reversed(), forKey: .upBlockTypes)

        try container.encode(self.inputChannels, forKey: .inputChannels)
        try container.encode(self.outputChannels, forKey: .outputChannels)
        try container.encode(self.convolutionInKernel, forKey: .convolutionInKernel)
        try container.encode(self.convolutionOutKernel, forKey: .convolutionOutKernel)
        try container.encode(self.blockOutChannels, forKey: .blockOutChannels)
        try container.encode(self.layersPerBlock, forKey: .layersPerBlock)
        try container.encode(self.midBlockLayers, forKey: .midBlockLayers)
        try container.encode(self.transformerLayersPerBlock, forKey: .transformerLayersPerBlock)
        try container.encode(self.numHeads, forKey: .numHeads)
        try container.encode(self.crossAttentionDimension, forKey: .crossAttentionDimension)
        try container.encode(self.normNumGroups, forKey: .normNumGroups)
        try container.encode(self.downBlockTypes, forKey: .downBlockTypes)
        try container.encodeIfPresent(self.additionEmbedType, forKey: .additionEmbedType)
        try container.encodeIfPresent(
            self.additionTimeEmbedDimension, forKey: .additionTimeEmbedDimension)
        try container.encodeIfPresent(
            self.projectionClassEmbeddingsInputDimension,
            forKey: .projectionClassEmbeddingsInputDimension)
    }
}

/// Configuration for ``StableDiffusion``
public struct DiffusionConfiguration: Codable {

    public enum BetaSchedule: String, Codable {
        case linear = "linear"
        case scaledLinear = "scaled_linear"
    }

    public var betaSchedule = BetaSchedule.scaledLinear
    public var betaStart: Float = 0.00085
    public var betaEnd: Float = 0.012
    public var trainSteps = 3

    enum CodingKeys: String, CodingKey {
        case betaSchedule = "beta_schedule"
        case betaStart = "beta_start"
        case betaEnd = "beta_end"
        case trainSteps = "num_train_timesteps"
    }
}


// port of https://github.com/ml-explore/mlx-examples/blob/main/stable_diffusion/stable_diffusion/model_io.py

/// Configuration for loading stable diffusion weights.
///
/// These options can be tuned to conserve memory.
public struct LoadConfiguration: Sendable {

    /// convert weights to float16
    public var float16 = true

    /// Quantization settings for the text encoder weights.
    public var textEncoderQuantization: WeightQuantization?

    /// Quantization settings for the UNet weights.
    public var unetQuantization: WeightQuantization?

    var releasesComponentsBetweenStages = false

    /// Compatibility switch for callers using the original all-components option.
    public var quantize: Bool {
        get { textEncoderQuantization != nil || unetQuantization != nil }
        set {
            textEncoderQuantization = newValue ? WeightQuantization(groupSize: 64, bits: 4) : nil
            unetQuantization = newValue ? WeightQuantization(groupSize: 32, bits: 8) : nil
        }
    }

    public var dType: DType {
        float16 ? .float16 : .float32
    }

    public init(float16: Bool = true, quantize: Bool = false) {
        self.float16 = float16
        self.textEncoderQuantization = quantize
            ? WeightQuantization(groupSize: 64, bits: 4) : nil
        self.unetQuantization = quantize
            ? WeightQuantization(groupSize: 32, bits: 8) : nil
    }

    public init(
        float16: Bool = true,
        textEncoderQuantization: WeightQuantization? = nil,
        unetQuantization: WeightQuantization? = nil
    ) {
        self.float16 = float16
        self.textEncoderQuantization = textEncoderQuantization
        self.unetQuantization = unetQuantization
    }
}

/// Parameters for evaluating a stable diffusion prompt and generating latents
public struct StableDiffusionEvaluateParameters: Sendable {

    /// `cfg` value from the preset
    public var cfgWeight: Float

    /// number of steps -- default is from the preset
    public var steps: Int

    /// number of images to generate at a time
    public var imageCount = 1
    public var decodingBatchSize = 1

    /// size of the latent tensor -- the result image is a factor of 8 larger than this
    public var latentSize = [64, 64]

    public var seed: UInt64
    public var prompt = ""
    public var negativePrompt = ""

    public init(
        cfgWeight: Float, steps: Int, imageCount: Int = 1, decodingBatchSize: Int = 1,
        latentSize: [Int] = [64, 64], seed: UInt64? = nil, prompt: String = "",
        negativePrompt: String = "") {
        self.cfgWeight = cfgWeight
        self.steps = steps
        self.imageCount = imageCount
        self.decodingBatchSize = decodingBatchSize
        self.latentSize = latentSize
        self.seed = seed ?? UInt64(Date.timeIntervalSinceReferenceDate * 1000)
        self.prompt = prompt
        self.negativePrompt = negativePrompt
    }
}

/// File types for ``StableDiffusionConfiguration/files``. Used by the presets to provide
/// relative file paths for different types of files.
enum StableDiffusionFileKey {
    case unetConfig
    case unetWeights
    case textEncoderConfig
    case textEncoderWeights
    case textEncoderConfig2
    case textEncoderWeights2
    case vaeConfig
    case vaeWeights
    case diffusionConfig
    case tokenizerVocabulary
    case tokenizerMerges
    case tokenizerVocabulary2
    case tokenizerMerges2
}

/// Stable diffusion configuration -- this selects the model to load.
///
/// Use the preset values:
/// - ``presetSDXLTurbo``
/// - ``presetStableDiffusion21Base``
///
/// or use the enum (convenient for command line tools):
///
/// - ``Preset/sdxlTurbo``
/// - ``Preset/sdxlTurbo``
///
/// Call ``download(hub:progressHandler:)`` to download the weights, then
/// ``textToImageGenerator(hub:configuration:)`` or
/// ``imageToImageGenerator(hub:configuration:)`` to produce the ``ImageGenerator``.
///
/// The ``ImageGenerator`` has a method to generate the latents:
/// - ``TextToImageGenerator/generateLatents(parameters:)``
/// - ``ImageToImageGenerator/generateLatents(image:parameters:strength:)``
///
/// Evaluate each of the latents from that iterator and use the decoder to turn the last latent
/// into an image:
///
/// - ``ImageGenerator/decode(xt:)``
///
/// Finally use ``StableDiffusionImage`` to save it to a file or convert to a CGImage for display.
public struct StableDiffusionConfiguration: Sendable {
    public let id: String
    let files: [StableDiffusionFileKey: String]
    public let defaultParameters: @Sendable () -> StableDiffusionEvaluateParameters
    let factory:
        @Sendable (HubApi, StableDiffusionConfiguration, LoadConfiguration) throws ->
            StableDiffusion

    public func download(
        hub: HubApi = .default, progressHandler: @escaping (Progress) -> Void = { _ in }
    ) async throws {
        let repo = Hub.Repo(id: self.id)
        try await hub.snapshot(
            from: repo, matching: Array(files.values), progressHandler: progressHandler)
    }

    public func textToImageGenerator(hub: HubApi = .default, configuration: LoadConfiguration)
        throws -> TextToImageGenerator?
    {
        try factory(hub, self, configuration) as? TextToImageGenerator
    }

    public func imageToImageGenerator(hub: HubApi = .default, configuration: LoadConfiguration)
        throws -> ImageToImageGenerator?
    {
        try factory(hub, self, configuration) as? ImageToImageGenerator
    }

    public enum Preset: String, Codable, CaseIterable, Sendable {
        case base
        case sdxlTurbo = "sdxl-turbo"

        public var configuration: StableDiffusionConfiguration {
            switch self {
            case .base: presetStableDiffusion21Base
            case .sdxlTurbo: presetSDXLTurbo
            }
        }
    }

    /// See https://huggingface.co/stabilityai/sdxl-turbo for the model details and license
    public static let presetSDXLTurbo = StableDiffusionConfiguration(
        id: "stabilityai/sdxl-turbo",
        files: [
            .unetConfig: "unet/config.json",
            .unetWeights: "unet/diffusion_pytorch_model.safetensors",
            .textEncoderConfig: "text_encoder/config.json",
            .textEncoderWeights: "text_encoder/model.safetensors",
            .textEncoderConfig2: "text_encoder_2/config.json",
            .textEncoderWeights2: "text_encoder_2/model.safetensors",
            .vaeConfig: "vae/config.json",
            .vaeWeights: "vae/diffusion_pytorch_model.safetensors",
            .diffusionConfig: "scheduler/scheduler_config.json",
            .tokenizerVocabulary: "tokenizer/vocab.json",
            .tokenizerMerges: "tokenizer/merges.txt",
            .tokenizerVocabulary2: "tokenizer_2/vocab.json",
            .tokenizerMerges2: "tokenizer_2/merges.txt",
        ],
        defaultParameters: { StableDiffusionEvaluateParameters(cfgWeight: 0, steps: 2) },
        factory: { hub, sdConfiguration, loadConfiguration in
            try StableDiffusionXL(
                hub: hub, configuration: sdConfiguration,
                loadConfiguration: loadConfiguration)
        }
    )

    /// See https://huggingface.co/stabilityai/stable-diffusion-2-1-base for the model details and license
    public static let presetStableDiffusion21Base = StableDiffusionConfiguration(
        id: "stabilityai/stable-diffusion-2-1-base",
        files: [
            .unetConfig: "unet/config.json",
            .unetWeights: "unet/diffusion_pytorch_model.safetensors",
            .textEncoderConfig: "text_encoder/config.json",
            .textEncoderWeights: "text_encoder/model.safetensors",
            .vaeConfig: "vae/config.json",
            .vaeWeights: "vae/diffusion_pytorch_model.safetensors",
            .diffusionConfig: "scheduler/scheduler_config.json",
            .tokenizerVocabulary: "tokenizer/vocab.json",
            .tokenizerMerges: "tokenizer/merges.txt",
        ],
        defaultParameters: { StableDiffusionEvaluateParameters(cfgWeight: 7.5, steps: 50) },
        factory: { hub, sdConfiguration, loadConfiguration in
            try StableDiffusionBase(
                hub: hub, configuration: sdConfiguration,
                loadConfiguration: loadConfiguration)
        }
    )

}

// MARK: - Key Mapping

func keyReplace(_ replace: String, _ with: String) -> @Sendable (String) -> String? {
    return { [replace, with] key in
        if key.contains(replace) {
            return key.replacingOccurrences(of: replace, with: with)
        }
        return nil
    }
}

func dropPrefix(_ prefix: String) -> @Sendable (String) -> String? {
    return { [prefix] key in
        if key.hasPrefix(prefix) {
            return String(key.dropFirst(prefix.count))
        }
        return nil
    }
}

// see map_unet_weights()

let unetRules: [@Sendable (String) -> String?] = [
    // Map up/downsampling
    keyReplace("downsamplers.0.conv", "downsample"),
    keyReplace("upsamplers.0.conv", "upsample"),

    // Map the mid block
    keyReplace("mid_block.resnets.0", "mid_blocks.0"),
    keyReplace("mid_block.attentions.0", "mid_blocks.1"),
    keyReplace("mid_block.resnets.1", "mid_blocks.2"),

    // Map attention layers
    keyReplace("to_k", "key_proj"),
    keyReplace("to_out.0", "out_proj"),
    keyReplace("to_q", "query_proj"),
    keyReplace("to_v", "value_proj"),

    // Map transformer ffn
    keyReplace("ff.net.2", "linear3"),
]

func unetRemap(key: String, value: MLXArray) -> [(String, MLXArray)] {
    var key = key
    var value = value

    for rule in unetRules {
        key = rule(key) ?? key
    }

    // Map transformer ffn
    if key.contains("ff.net.0") {
        let k1 = key.replacingOccurrences(of: "ff.net.0.proj", with: "linear1")
        let k2 = key.replacingOccurrences(of: "ff.net.0.proj", with: "linear2")
        let (v1, v2) = value.split()
        return [(k1, v1), (k2, v2)]
    }

    if key.contains("conv_shortcut.weight") {
        value = value.squeezed()
    }

    // Transform the weights from 1x1 convs to linear
    if value.ndim == 4 && (key.contains("proj_in") || key.contains("proj_out")) {
        value = value.squeezed()
    }

    if value.ndim == 4 {
        value = value.transposed(0, 2, 3, 1)
        value = value.reshaped(-1).reshaped(value.shape)
    }

    return [(key, value)]
}

let clipRules: [@Sendable (String) -> String?] = [
    dropPrefix("text_model."),
    dropPrefix("embeddings."),
    dropPrefix("encoder."),

    // Map attention layers
    keyReplace("self_attn.", "attention."),
    keyReplace("q_proj.", "query_proj."),
    keyReplace("k_proj.", "key_proj."),
    keyReplace("v_proj.", "value_proj."),

    // Map ffn layers
    keyReplace("mlp.fc1", "linear1"),
    keyReplace("mlp.fc2", "linear2"),
]

func clipRemap(key: String, value: MLXArray) -> [(String, MLXArray)] {
    var key = key

    for rule in clipRules {
        key = rule(key) ?? key
    }

    // not used
    if key == "position_ids" {
        return []
    }

    return [(key, value)]
}

let vaeRules: [@Sendable (String) -> String?] = [
    // Map up/downsampling
    keyReplace("downsamplers.0.conv", "downsample"),
    keyReplace("upsamplers.0.conv", "upsample"),

    // Map attention layers
    keyReplace("to_k", "key_proj"),
    keyReplace("to_out.0", "out_proj"),
    keyReplace("to_q", "query_proj"),
    keyReplace("to_v", "value_proj"),

    // Map the mid block
    keyReplace("mid_block.resnets.0", "mid_blocks.0"),
    keyReplace("mid_block.attentions.0", "mid_blocks.1"),
    keyReplace("mid_block.resnets.1", "mid_blocks.2"),

    keyReplace("mid_blocks.1.key.", "mid_blocks.1.key_proj."),
    keyReplace("mid_blocks.1.query.", "mid_blocks.1.query_proj."),
    keyReplace("mid_blocks.1.value.", "mid_blocks.1.value_proj."),
    keyReplace("mid_blocks.1.proj_attn.", "mid_blocks.1.out_proj."),

]

func vaeRemap(key: String, value: MLXArray) -> [(String, MLXArray)] {
    var key = key
    var value = value

    for rule in vaeRules {
        key = rule(key) ?? key
    }

    // Map the quant/post_quant layers
    if key.contains("quant_conv") {
        key = key.replacingOccurrences(of: "quant_conv", with: "quant_proj")
        value = value.squeezed()
    }

    // Map the conv_shortcut to linear
    if key.contains("conv_shortcut.weight") {
        value = value.squeezed()
    }

    if value.ndim == 4 {
        value = value.transposed(0, 2, 3, 1)
        value = value.reshaped(-1).reshaped(value.shape)
    }

    return [(key, value)]
}
