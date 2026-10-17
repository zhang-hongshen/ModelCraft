//
//  ModelStoreModel.swift
//  ModelCraft
//
//  Created by Hongshen on 4/3/26.
//

import Foundation

struct ModelStoreModel: Decodable, ModelEntity {
    let id: String
    let downloads: Int
    let tags: [String]
    let pipelineTag: String?
    
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
