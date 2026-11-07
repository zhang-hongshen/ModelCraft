//
//  LocalModel.swift
//  ModelCraft
//
//  Created by Hongshen on 2/3/26.
//

import Foundation
import Observation

import HuggingFace
import MLXLLM
import MLXVLM

struct LocalModel: ModelEntity, Hashable, Sendable {

    static let defaultContextWindow = 32_768
    
    let id: String
    
    let createdAt: Date
    
    let size: Int64

    let contextWindow: Int
    
    init(
        id: String,
        size: Int64,
        createdAt: Date = .now,
        contextWindow: Int = LocalModel.defaultContextWindow
    ) {
        self.id = id
        self.size = size
        self.createdAt = createdAt
        self.contextWindow = contextWindow
    }
    
}

@MainActor
@Observable
final class LocalModelStore {

    private(set) var models: [LocalModel]

    private var reloadGeneration = 0
    private let fileManager: FileManager

    init(
        models: [LocalModel] = [],
        fileManager: FileManager = .default
    ) {
        self.models = models
        self.fileManager = fileManager
    }

    func contains(_ modelID: String) -> Bool {
        models.contains { $0.id == modelID }
    }

    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        var discovered: [String: URL] = [:]
        let cache = HubCache.default
        let repositories = (try? fileManager.contentsOfDirectory(
            at: cache.cacheDirectory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        for repository in repositories where repository.lastPathComponent.hasPrefix("models--") {
            let id = String(repository.lastPathComponent.dropFirst("models--".count))
                .replacingOccurrences(of: "--", with: "/")
            if let directory = cache.cachedModelDirectory(id: id) {
                discovered[id] = directory
            }
        }

        var result: [LocalModel] = []
        for (id, directory) in discovered {
            guard !ToolDefinition.modelIDs.contains(id) else { continue }
            guard let data = try? Data(contentsOf: directory.appending(path: "config.json")),
                  let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modelType = config["model_type"] as? String else { continue }
            // A shared cache also contains speech, diffusion and Python-only models.
            let supported = await LLMTypeRegistry.shared.contains(modelType)
            let visionSupported = await VLMTypeRegistry.shared.contains(modelType)
            guard supported || visionSupported || id == DeepSeekFlashConfiguration.repositoryID,
                  hasWeights(in: directory) else { continue }
            let values = try? directory.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            result.append(LocalModel(
                id: id, size: directorySize(at: directory),
                createdAt: values?.creationDate ?? values?.contentModificationDate ?? .distantPast,
                contextWindow: ModelContextConfiguration.contextWindow(in: directory)))
        }
        guard generation == reloadGeneration, !Task.isCancelled else { return }
        models = result.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
        }
    }

    private func hasWeights(in directory: URL) -> Bool {
        let indexURL = directory.appending(path: "model.safetensors.index.json")
        if fileManager.fileExists(atPath: indexURL.path) {
            guard let data = try? Data(contentsOf: indexURL),
                  let index = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let weights = index["weight_map"] as? [String: String], !weights.isEmpty else { return false }
            return Set(weights.values).allSatisfy {
                fileManager.fileExists(atPath: directory.appending(path: $0).path)
            }
        }
        let files = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.contains { $0.pathExtension == "safetensors" }
    }

    private func directorySize(at directory: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        return enumerator.reduce(into: Int64(0)) { result, item in
            guard let fileURL = item as? URL,
                  let values = try? fileURL.resolvingSymlinksInPath().resourceValues(forKeys: [
                    .isRegularFileKey,
                    .fileSizeKey,
                  ]),
                  values.isRegularFile == true else {
                return
            }
            result += Int64(values.fileSize ?? 0)
        }
    }
}

private enum ModelContextConfiguration {

    private static let scalableRoPETypes: Set<String> = [
        "linear",
        "dynamic",
        "yarn",
        "deepseek_yarn",
        "telechat3-yarn",
        "longrope",
        "llama3",
    ]

    static func contextWindow(in modelDirectory: URL) -> Int {
        let configURL = modelDirectory.appending(path: "config.json")
        if let data = try? Data(contentsOf: configURL),
           let config = try? JSONDecoder().decode(ModelConfig.self, from: data),
           let contextWindow = config.contextWindow {
            return contextWindow
        }

        let tokenizerConfigURL = modelDirectory.appending(path: "tokenizer_config.json")
        if let data = try? Data(contentsOf: tokenizerConfigURL),
           let config = try? JSONDecoder().decode(TokenizerConfig.self, from: data),
           let modelMaxLength = config.modelMaxLength,
           modelMaxLength > 0,
           modelMaxLength < 10_000_000 {
            return Int(modelMaxLength)
        }

        return LocalModel.defaultContextWindow
    }

    private struct ModelConfig: Decodable {
        let maxPositionEmbeddings: Int?
        let ropeScaling: RoPEConfiguration?
        let ropeParameters: RoPEConfiguration?
        let textConfig: LanguageConfig?
        let languageConfig: LanguageConfig?

        enum CodingKeys: String, CodingKey {
            case maxPositionEmbeddings = "max_position_embeddings"
            case ropeScaling = "rope_scaling"
            case ropeParameters = "rope_parameters"
            case textConfig = "text_config"
            case languageConfig = "language_config"
        }

        var contextWindow: Int? {
            let nestedConfig = textConfig?.maxPositionEmbeddings != nil
                ? textConfig
                : languageConfig
            return ModelContextConfiguration.resolve(
                declaredLength: nestedConfig?.maxPositionEmbeddings
                    ?? maxPositionEmbeddings,
                rope: nestedConfig?.ropeScaling
                    ?? nestedConfig?.ropeParameters
                    ?? ropeScaling
                    ?? ropeParameters)
        }
    }

    private struct LanguageConfig: Decodable {
        let maxPositionEmbeddings: Int?
        let ropeScaling: RoPEConfiguration?
        let ropeParameters: RoPEConfiguration?

        enum CodingKeys: String, CodingKey {
            case maxPositionEmbeddings = "max_position_embeddings"
            case ropeScaling = "rope_scaling"
            case ropeParameters = "rope_parameters"
        }
    }

    private struct RoPEConfiguration: Decodable {
        let type: String?
        let ropeType: String?
        let factor: Double?
        let originalMaxPositionEmbeddings: Int?

        enum CodingKeys: String, CodingKey {
            case type
            case ropeType = "rope_type"
            case factor
            case originalMaxPositionEmbeddings = "original_max_position_embeddings"
        }
    }

    private struct TokenizerConfig: Decodable {
        let modelMaxLength: Double?

        enum CodingKeys: String, CodingKey {
            case modelMaxLength = "model_max_length"
        }
    }

    private static func resolve(
        declaredLength: Int?,
        rope: RoPEConfiguration?
    ) -> Int? {
        guard let declaredLength else { return nil }
        guard let rope,
              let ropeType = rope.ropeType ?? rope.type,
              scalableRoPETypes.contains(ropeType.lowercased()),
              let factor = rope.factor,
              factor > 1,
              let originalLength = rope.originalMaxPositionEmbeddings else {
            return declaredLength
        }

        return max(declaredLength, Int(Double(originalLength) * factor))
    }
}
