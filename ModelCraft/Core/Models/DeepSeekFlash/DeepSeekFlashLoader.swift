//
//  DeepSeekFlashLoader.swift
//  ModelCraft
//
//  Created by Hongshen on 26/9/26.
//

import Foundation
import Hub
import MLX
import MLXNN

public enum DeepSeekFlashLoaderError: Error, LocalizedError {
    case fileNotFound(URL)
    case invalidConfiguration(URL)
    case invalidIndex(URL)
    case emptyWeights(URL)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url): "DeepSeekFlash file is missing: \(url.path)"
        case .invalidConfiguration(let url): "Invalid DeepSeekFlash config: \(url.path)"
        case .invalidIndex(let url): "Invalid DeepSeekFlash weight index: \(url.path)"
        case .emptyWeights(let url): "No DeepSeekFlash weights were loaded from \(url.path)"
        }
    }
}

enum DeepSeekFlashLoader {
    private struct WeightIndex: Decodable {
        let weightMap: [String: String]

        private enum CodingKeys: String, CodingKey {
            case weightMap = "weight_map"
        }
    }

    static func resolve(hub: HubApi, path: String) throws -> URL {
        let url = hub.localRepoLocation(Hub.Repo(id: DeepSeekFlashConfiguration.repositoryID))
            .appending(component: path)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw DeepSeekFlashLoaderError.fileNotFound(url)
        }
        return url
    }

    static func loadConfiguration(hub: HubApi) throws -> DeepSeekFlashConfiguration {
        let url = try resolve(hub: hub, path: "config.json")
        do {
            return try JSONDecoder().decode(
                DeepSeekFlashConfiguration.self,
                from: Data(contentsOf: url))
        } catch {
            throw DeepSeekFlashLoaderError.invalidConfiguration(url)
        }
    }

    private static func loadWeights(
        from url: URL,
        into model: Module,
        mapper: (String, MLXArray) -> [(String, MLXArray)] = { [($0, $1)] }
    ) throws {
        let weights = try MLX.loadArrays(url: url).flatMap {
            mapper($0.key, $0.value)
        }
        guard !weights.isEmpty else {
            throw DeepSeekFlashLoaderError.emptyWeights(url)
        }
        try model.update(
            parameters: ModuleParameters.unflattened(weights),
            verify: .none)
    }

    static func loadTransformer(
        hub: HubApi,
        configuration: DeepSeekFlashConfiguration,
        maximumSequenceLength: Int
    ) throws -> DeepSeekFlashTransformer {
        let indexURL = try resolve(hub: hub, path: "model.safetensors.index.json")
        let weightMap = try loadWeightMap(from: indexURL)
        let layerURLs = try resolveLayerURLs(
            hub: hub,
            configuration: configuration,
            weightMap: weightMap,
            indexURL: indexURL)
        let shardURLs = try Set(weightMap.values).sorted().map {
            try resolve(hub: hub, path: $0)
        }
        let totalSize = try shardURLs.reduce(UInt64(0)) {
            $0 + (try fileSize($1))
        }
        let fullLoad = totalSize <= ProcessInfo.processInfo.physicalMemory / 4 * 3

        let transformer = DeepSeekFlashTransformer(
            configuration: configuration,
            maximumSequenceLength: maximumSequenceLength)
        if fullLoad {
            transformer.layers = (0 ..< configuration.numHiddenLayers).map {
                DeepSeekFlashTransformerBlock(
                    layerID: $0,
                    configuration: configuration)
            }
            for url in shardURLs {
                try loadWeights(from: url, into: transformer)
            }
        } else {
            // DSpark stages only draft tokens, so streaming leaves them unloaded.
            transformer.mtp = []
            let dsparkURLs = try Set(weightMap.compactMap { name, shardName in
                name.hasPrefix("mtp.") ? shardName : nil
            }).map { try resolve(hub: hub, path: $0) }
            let streamedURLs = Set(layerURLs).union(dsparkURLs)
            for url in shardURLs where !streamedURLs.contains(url) {
                try loadWeights(from: url, into: transformer)
            }
            transformer.streamingLayerURLs = layerURLs
        }
        eval(transformer)
        Memory.clearCache()
        return transformer
    }

    /// Builds one Transformer block from its shard. Tensors stay lazy until the
    /// forward pass evaluates them, so only the experts a step routes to are read.
    static func loadTransformerBlock(
        layerID: Int,
        url: URL,
        configuration: DeepSeekFlashConfiguration
    ) throws -> DeepSeekFlashTransformerBlock {
        let block = DeepSeekFlashTransformerBlock(
            layerID: layerID,
            configuration: configuration)
        let prefix = "layers.\(layerID)."
        try loadWeights(from: url, into: block) { name, array in
            guard name.hasPrefix(prefix) else { return [] }
            return [(String(name.dropFirst(prefix.count)), array)]
        }
        return block
    }

    private static func loadWeightMap(from url: URL) throws -> [String: String] {
        do {
            return try JSONDecoder().decode(
                WeightIndex.self,
                from: Data(contentsOf: url)).weightMap
        } catch {
            throw DeepSeekFlashLoaderError.invalidIndex(url)
        }
    }

    private static func resolveLayerURLs(
        hub: HubApi,
        configuration: DeepSeekFlashConfiguration,
        weightMap: [String: String],
        indexURL: URL
    ) throws -> [URL] {
        try (0 ..< configuration.numHiddenLayers).map { layerID in
            let prefix = "layers.\(layerID)."
            let shardNames = Set(weightMap.compactMap { name, shardName in
                name.hasPrefix(prefix) ? shardName : nil
            })
            guard shardNames.count == 1, let shardName = shardNames.first else {
                throw DeepSeekFlashLoaderError.invalidIndex(indexURL)
            }
            return try resolve(hub: hub, path: shardName)
        }
    }

    private static func fileSize(_ url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw DeepSeekFlashLoaderError.fileNotFound(url)
        }
        return UInt64(size)
    }
}
