//
//  LocalModel.swift
//  ModelCraft
//
//  Created by Hongshen on 2/3/26.
//

import Foundation
import Observation

import Hub

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

    private let modelsDirectory: URL?
    private let fileManager: FileManager

    init(
        models: [LocalModel] = [],
        modelsDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.models = models
        self.modelsDirectory = modelsDirectory
        self.fileManager = fileManager
    }

    func contains(_ modelID: String) -> Bool {
        models.contains { $0.id == modelID }
    }

    func reload() {
        models = discoverModels()
    }

    private func discoverModels() -> [LocalModel] {
        let modelsDirectory = modelsDirectory ?? HubApi.modelsDirectory
        guard let authors = try? fileManager.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return authors.flatMap { authorDirectory -> [LocalModel] in
            guard isDirectory(authorDirectory),
                  let modelDirectories = try? fileManager.contentsOfDirectory(
                    at: authorDirectory,
                    includingPropertiesForKeys: [
                        .isDirectoryKey,
                        .creationDateKey,
                        .contentModificationDateKey,
                    ],
                    options: [.skipsHiddenFiles]
                  ) else {
                return []
            }

            return modelDirectories.compactMap { modelDirectory in
                let modelID = "\(authorDirectory.lastPathComponent)/\(modelDirectory.lastPathComponent)"
                guard isDirectory(modelDirectory),
                      !ToolDefinition.modelIDs.contains(modelID) else {
                    return nil
                }
                let values = try? modelDirectory.resourceValues(forKeys: [
                    .creationDateKey,
                    .contentModificationDateKey,
                ])
                return LocalModel(
                    id: modelID,
                    size: directorySize(at: modelDirectory),
                    createdAt: values?.creationDate ?? values?.contentModificationDate ?? .distantPast,
                    contextWindow: ModelContextConfiguration.contextWindow(
                        in: modelDirectory)
                )
            }
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
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
                  let values = try? fileURL.resourceValues(forKeys: [
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
