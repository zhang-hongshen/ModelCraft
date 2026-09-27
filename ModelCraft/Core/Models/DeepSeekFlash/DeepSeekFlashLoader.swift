//
//  DeepSeekFlashLoader.swift
//  ModelCraft
//
//  Created by Hongshen on 26/9/26.
//

import Darwin
import Foundation
import Hub
import MLX
import MLXNN

// libSystem exports this on macOS even though the SDK only exposes the declaration on iOS.
@_silgen_name("os_proc_available_memory")
private func osProcAvailableMemory() -> UInt

public enum DeepSeekFlashLoaderError: Error, LocalizedError {
    case fileNotFound(URL)
    case invalidConfiguration(URL)
    case invalidIndex(URL)
    case emptyWeights(URL)
    case insufficientMemory(required: UInt64, available: UInt64)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url): "DeepSeekFlash file is missing: \(url.path)"
        case .invalidConfiguration(let url): "Invalid DeepSeekFlash config: \(url.path)"
        case .invalidIndex(let url): "Invalid DeepSeekFlash weight index: \(url.path)"
        case .emptyWeights(let url): "No DeepSeekFlash weights were loaded from \(url.path)"
        case .insufficientMemory(let required, let available):
            "DeepSeekFlash layer group needs \(required) bytes, but only \(available) bytes are available"
        }
    }
}

enum DeepSeekFlashLoader {
    struct LayerGroup {
        let range: Range<Int>
        let blocks: [DeepSeekFlashTransformerBlock]
    }

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
        let fullLoad = totalSize <= availableLoadingBudget()

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
            let layerURLSet = Set(layerURLs)
            for url in shardURLs where !layerURLSet.contains(url) {
                try loadWeights(from: url, into: transformer)
            }
            transformer.streamingLayerURLs = layerURLs
        }
        eval(transformer)
        Memory.clearCache()
        return transformer
    }

    static func loadTransformerBlocks(
        startingAt firstLayer: Int,
        urls: [URL],
        configuration: DeepSeekFlashConfiguration
    ) throws -> LayerGroup {
        precondition(urls.indices.contains(firstLayer))
        let budget = availableLoadingBudget()
        var required = UInt64(0)
        var endLayer = firstLayer

        while endLayer < urls.count {
            let size = try fileSize(urls[endLayer])
            guard required + size <= budget else { break }
            required += size
            endLayer += 1
        }
        guard endLayer > firstLayer else {
            throw DeepSeekFlashLoaderError.insufficientMemory(
                required: try fileSize(urls[firstLayer]),
                available: budget)
        }

        let range = firstLayer ..< endLayer
        var blocks = [DeepSeekFlashTransformerBlock]()
        blocks.reserveCapacity(range.count)
        for layerID in range {
            let url = urls[layerID]
            let size = try fileSize(url)
            let liveBudget = availableLoadingBudget()
            guard size <= liveBudget else {
                throw DeepSeekFlashLoaderError.insufficientMemory(
                    required: size,
                    available: liveBudget)
            }
            let prefix = "layers.\(layerID)."
            blocks.append(try loadBlock(
                from: url,
                mapper: { name, array in
                    guard name.hasPrefix(prefix) else { return [] }
                    return [(String(name.dropFirst(prefix.count)), array)]
                }
            ) {
                DeepSeekFlashTransformerBlock(
                    layerID: layerID,
                    configuration: configuration)
            })
        }
        return LayerGroup(range: range, blocks: blocks)
    }

    private static func loadBlock<Block: Module>(
        from url: URL,
        mapper: (String, MLXArray) -> [(String, MLXArray)],
        makeBlock: () -> Block
    ) throws -> Block {
        let block = makeBlock()
        try loadWeights(from: url, into: block, mapper: mapper)
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

    private static func availableLoadingBudget() -> UInt64 {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let targetPeak = physicalMemory / 4 * 3
        let snapshot = Memory.snapshot()
        let mlxMemory = UInt64(max(snapshot.activeMemory, 0))
            + UInt64(max(snapshot.cacheMemory, 0))
        let targetBudget = targetPeak > mlxMemory ? targetPeak - mlxMemory : 0
        return min(UInt64(osProcAvailableMemory()), targetBudget)
    }
}
