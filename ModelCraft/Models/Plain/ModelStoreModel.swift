//
//  ModelStoreModel.swift
//  ModelCraft
//
//  Created by Hongshen on 4/3/26.
//

import Foundation
import Darwin
import Metal

struct ModelStoreModel: Decodable, ModelEntity, Sendable {
    let id: String
    let downloads: Int
    let tags: [String]
    let pipelineTag: String?
    let config: Configuration?
    let safetensors: SafeTensors?
    let sha: String?
    var assessment: Assessment?

    var deviceFit: ModelDeviceFit { assessment?.fit ?? .limited }
    var downloadSizeInBytes: Int64? { assessment?.downloadSizeInBytes }

    private enum CodingKeys: String, CodingKey {
        case id, downloads, tags, pipelineTag, config, safetensors, sha
    }

    struct SafeTensors: Decodable, Sendable {
        let parameters: [String: Double]?

        var weightBytes: Double? {
            // Packed quantized tensors are counted in their stored dtype (e.g. U32),
            // so this also handles mixed precision without treating packed values as
            // the original parameter count. Repository disk usage includes other files.
            let dtypeBytes: [String: Double] = [
                "BOOL": 1, "U8": 1, "I8": 1, "F8_E4M3": 1, "F8_E5M2": 1,
                "BF16": 2, "F16": 2, "I16": 2, "U16": 2,
                "F32": 4, "I32": 4, "U32": 4, "F64": 8, "I64": 8, "U64": 8,
            ]
            if let parameters, !parameters.isEmpty,
               parameters.allSatisfy({ dtypeBytes[$0.key] != nil && $0.value >= 0 }) {
                let bytes = parameters.reduce(0.0) { $0 + $1.value * dtypeBytes[$1.key]! }
                if bytes > 0, bytes.isFinite { return bytes }
            }

            return nil
        }
    }

    struct Configuration: Decodable, Sendable {
        let modelType: String?
        let architectures: [String]?
        let attention: AttentionConfiguration
        let hasVision: Bool
        let quantizationMode: String?

        private enum CodingKeys: String, CodingKey {
            case modelType, architectures, textConfig, languageConfig, visionConfig
            case quantization, quantizationConfig
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            modelType = try container.decodeIfPresent(String.self, forKey: .modelType)
            architectures = try container.decodeIfPresent([String].self, forKey: .architectures)
            attention = try container.decodeIfPresent(AttentionConfiguration.self, forKey: .textConfig)
                ?? container.decodeIfPresent(AttentionConfiguration.self, forKey: .languageConfig)
                ?? AttentionConfiguration(from: decoder)
            hasVision = try container.contains(.visionConfig) && !container.decodeNil(forKey: .visionConfig)
            let quantization = try container.decodeIfPresent(Quantization.self, forKey: .quantization)
                ?? container.decodeIfPresent(Quantization.self, forKey: .quantizationConfig)
            quantizationMode = quantization?.mode
        }

        private struct Quantization: Decodable {
            let mode: String?
        }
    }

    struct AttentionConfiguration: Decodable, Sendable {
        let numHiddenLayers: Int?
        let numKeyValueHeads: Int?
        let numAttentionHeads: Int?
        let headDim: Int?
        let maxPositionEmbeddings: Int?
        let kvLoraRank: Int?
        let layerTypes: [String]?

        /// An upper bound for ordinary fp16 K/V caches. Treat sliding attention as
        /// full attention; unfamiliar hybrid/recurrent/latent caches stay unestimated.
        var estimatedKVBytes: Double? {
            guard kvLoraRank == nil,
                  layerTypes?.contains(where: { $0 != "full_attention" && $0 != "sliding_attention" }) != true,
                  let layers = numHiddenLayers, layers > 0,
                  let heads = numKeyValueHeads ?? numAttentionHeads, heads > 0,
                  let dimension = headDim, dimension > 0,
                  let maximum = maxPositionEmbeddings, maximum > 0 else { return nil }
            return 2 * Double(layers) * Double(heads) * Double(dimension)
                * Double(min(maximum, 8_192)) * 2
        }
    }

    struct Assessment: Sendable {
        static let version = 2
        let fit: ModelDeviceFit
        let downloadSizeInBytes: Int64?
        let weightBytes: Double?
        let runtimeBytes: Double?
        let contextTokens: Int?
        let hasReliableWeights: Bool
    }

    func isConversationModel(configuration: Configuration? = nil) -> Bool {
        let identifiers = [id] + tags.filter { $0.hasPrefix("base_model:") }
        if identifiers.contains(where: {
            $0.lowercased().firstMatch(of: #/(?:^|[-_/:])(?:embeddings?|rerank(?:er|ing)?)(?:[-_/:]|$)/#) != nil
        }) { return false }
        let nonGenerativeTags: Set<String> = [
            "feature-extraction", "sentence-similarity", "sentence-transformers", "text-ranking",
        ]
        if tags.contains(where: { nonGenerativeTags.contains($0.lowercased()) }) { return false }
        return (configuration ?? config)?.architectures?.contains(where: {
            let name = $0.lowercased()
            return name.contains("embedding") || name.contains("sequenceclassification") || name.contains("rerank")
        }) != true
    }

    /// Assesses this exact checkpoint; never substitutes a smaller quantization or
    /// assumes expert offloading that ModelCraft's ordinary MLX loader does not do.
    func assess(configuration: Configuration?, weightBytes: Double?, downloadSizeInBytes: Int64?) -> Assessment {
        let hardware = ModelStoreHardware.current
        let weights = weightBytes ?? estimatedWeightBytes
        let reliable = weightBytes != nil
        let gib = 1_073_741_824.0
        let hasVision = configuration?.hasVision == true || category == .vision || category == .omni
        let overhead = 0.5 * gib + (hasVision ? gib : 0)
        let basicMemory = weights.map { $0 * 1.05 + overhead }
        let kv = configuration?.attention.estimatedKVBytes
        let runtime = basicMemory.flatMap { basic in kv.map { basic + $0 } }
        let budget = Double(hardware.modelMemoryBudget)
        let fit: ModelDeviceFit
        if !hardware.supportsMLX || budget <= 0 {
            fit = .incompatible
        } else if reliable, let basicMemory, basicMemory > budget * 0.98 {
            fit = .incompatible
        } else if reliable, let runtime, runtime <= budget * 0.8,
                  configuration?.quantizationMode == nil || configuration?.quantizationMode == "affine" {
            fit = .recommended
        } else {
            fit = .limited
        }
        return Assessment(
            fit: fit, downloadSizeInBytes: downloadSizeInBytes,
            weightBytes: weights, runtimeBytes: runtime,
            contextTokens: configuration?.attention.maxPositionEmbeddings.map { min($0, 8_192) },
            hasReliableWeights: reliable)
    }

    private var estimatedWeightBytes: Double? {
        if let bytes = safetensors?.weightBytes { return bytes }
        let name = displayName.lowercased()
        // Use total parameters, never the A3B-style active count of a MoE model.
        // NxM names conservatively account for every expert, not just active ones.
        guard let match = name.firstMatch(of: #/(?:^|[-_])(\d+(?:\.\d+)?)(?:x(\d+(?:\.\d+)?))?([bm])(?:[-_]|$)/#),
              let count = Double(match.1) else { return nil }
        let experts = match.2.flatMap { Double($0) } ?? 1
        let parameters = count * experts * (match.3 == "b" ? 1_000_000_000 : 1_000_000)
        let bits: Double
        if let quant = name.firstMatch(of: #/(?:^|[-_])(\d+(?:\.\d+)?)[-_]?bits?(?:[-_]|$)/#),
           let value = Double(quant.1), value > 0, value <= 16 {
            bits = value
        } else if name.contains("bf16") || name.contains("fp16") || name.contains("float16") {
            bits = 16
        } else if name.contains("fp32") || name.contains("float32") {
            bits = 32
        } else if name.contains("mxfp4") {
            bits = 4.25
        } else if name.contains("fp8") {
            bits = 8
        } else {
            // Unknown precision cannot support a confident recommendation.
            return nil
        }
        // Quantization scales and unquantized layers add to the packed weights.
        return parameters * bits / 8 * (bits < 16 ? 1.1 : 1)
    }
    
    var category: ModelCategory? {
        pipelineTag.flatMap(ModelCategory.init(rawValue:))
    }
    
    /// The Hugging Face organization behind the model family, whose avatar serves as its logo.
    /// mlx-community conversions often omit `base_model`, so the name prefix is checked first.
    var organization: String? {
        let name = displayName.lowercased()
        if let family = Self.familyOrganizations.first(where: { name.hasPrefix($0.prefix) }) {
            return family.organization
        }
        return tags.lazy
            .filter { $0.hasPrefix("base_model:") }
            .compactMap { $0.split(separator: ":").last?.split(separator: "/").first.map(String.init) }
            .first { $0 != "mlx-community" }
    }
    
    private static let familyOrganizations: [(prefix: String, organization: String)] = [
        ("gemma", "google"),
        ("qwen", "Qwen"),
        ("qwq", "Qwen"),
        ("llama", "meta-llama"),
        ("meta-llama", "meta-llama"),
        ("mistral", "mistralai"),
        ("ministral", "mistralai"),
        ("magistral", "mistralai"),
        ("devstral", "mistralai"),
        ("pixtral", "mistralai"),
        ("deepseek", "deepseek-ai"),
        ("kimi", "moonshotai"),
        ("gpt-oss", "openai"),
        ("phi", "microsoft"),
        ("glm", "zai-org"),
        ("minicpm", "openbmb"),
        ("minimax", "MiniMaxAI"),
        ("nemotron", "nvidia"),
        ("smol", "HuggingFaceTB"),
        ("granite", "ibm-granite"),
        ("olmo", "allenai"),
        ("internvl", "OpenGVLab"),
        ("sensenova", "sensenova"),
        ("hunyuan", "tencent"),
        ("ernie", "baidu"),
        ("lfm", "LiquidAI"),
        ("exaone", "LGAI-EXAONE"),
        ("falcon", "tiiuae"),
    ]
    
}

enum ModelDeviceFit: String, CaseIterable, Identifiable, Sendable {
    case recommended, limited, incompatible

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .recommended: "Recommended"
        case .limited: "Performance Limited"
        case .incompatible: "Incompatible"
        }
    }

    var systemImage: String {
        switch self {
        case .recommended: "checkmark.circle.fill"
        case .limited: "exclamationmark.triangle.fill"
        case .incompatible: "xmark.circle.fill"
        }
    }
}

/// Stable device capabilities, sampled once per process without loading any weights.
struct ModelStoreHardware {
    static let current = ModelStoreHardware()

    let chipName: String
    let physicalMemory: UInt64
    let supportsMLX: Bool
    let modelMemoryBudget: UInt64

    private init() {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var name = [CChar](repeating: 0, count: max(size, 1))
        let nameResult = sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0)
        let device = MTLCreateSystemDefaultDevice()
        chipName = nameResult == 0 ? String(cString: name) : (device?.name ?? "Mac")
        physicalMemory = ProcessInfo.processInfo.physicalMemory
        var arm64: Int32 = 0
        var arm64Size = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &arm64, &arm64Size, nil, 0)
        supportsMLX = arm64 == 1 && device?.hasUnifiedMemory == true
        // Leave memory for macOS and other apps, and respect Metal's device budget.
        let reserve = max(UInt64(2 * 1_073_741_824), physicalMemory / 5)
        let available = physicalMemory > reserve ? physicalMemory - reserve : 0
        modelMemoryBudget = min(available, device?.recommendedMaxWorkingSetSize ?? 0)
    }
}

/// A Model Store category. The raw value is the Hugging Face `pipeline_tag` it requests.
enum ModelCategory: String, CaseIterable, Identifiable {
    
    case text = "text-generation"
    case vision = "image-text-to-text"
    case omni = "any-to-any"
    
    var id: String { rawValue }
    
    var title: LocalizedStringResource {
        switch self {
        case .text: "Text"
        case .vision: "Vision"
        case .omni: "Omni"
        }
    }
    
    var systemImage: String {
        switch self {
        case .text: "text.bubble"
        case .vision: "eye"
        case .omni: "sparkles"
        }
    }
}
