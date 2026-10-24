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

    static func loadTransformer(
        hub: HubApi,
        configuration: DeepSeekFlashConfiguration,
        maximumSequenceLength: Int
    ) throws -> DeepSeekFlashTransformer {
        let indexURL = try resolve(hub: hub, path: "model.safetensors.index.json")
        let weightMap = try loadWeightMap(from: indexURL)
        let shardURLs = try Set(weightMap.values).sorted().map {
            try resolve(hub: hub, path: $0)
        }
        let totalSize = try shardURLs.reduce(UInt64(0)) {
            $0 + (try fileSize($1))
        }
        let memoryLimit = Int(ProcessInfo.processInfo.physicalMemory / 4 * 3)
        let streamsExperts = totalSize > UInt64(memoryLimit)

        let transformer = DeepSeekFlashTransformer(
            configuration: configuration,
            maximumSequenceLength: maximumSequenceLength,
            streamsExperts: streamsExperts)
        let expertCache = DeepSeekFlashExpertCache()
        if streamsExperts {
            let blocks = transformer.layers.enumerated().map { ("layers.\($0).", $1.feedForward) }
                + transformer.mtp.enumerated().map { ("mtp.\($0).", $1.feedForward) }
            for (prefix, feedForward) in blocks {
                feedForward.expertSource = DeepSeekFlashExpertSource(
                    cache: expertCache,
                    url: try resolveBlockURL(
                        hub: hub, prefix: prefix, weightMap: weightMap, indexURL: indexURL),
                    prefix: prefix + "ffn.experts.")
            }
        }

        for url in shardURLs {
            try loadWeights(from: url, into: transformer, stacksExperts: !streamsExperts)
        }
        eval(transformer)

        if streamsExperts {
            // Everything but the routed experts stays resident; the experts get what is left.
            let residentBytes = transformer.parameters().flattened().reduce(0) {
                $0 + $1.1.nbytes
            }
            let cacheBytes = DeepSeekFlashCache.byteCount(
                configuration: configuration,
                maximumSequenceLength: transformer.maximumSequenceLength)
            let expertBytes = configuration.hiddenSize * configuration.moeIntermediateSize * 3
                * 17 / 32
            let workingBytes = 2 * 32 * expertBytes
            expertCache.budget = max(memoryLimit - residentBytes - cacheBytes - workingBytes, 0)
        }
        Memory.clearCache()
        return transformer
    }

    /// Loads one shard. Routed experts are stacked per projection when resident and skipped when
    /// they are read from disk per step.
    private static func loadWeights(
        from url: URL,
        into model: Module,
        stacksExperts: Bool
    ) throws {
        var weights = [(String, MLXArray)]()
        var experts = [String: [Int: MLXArray]]()
        for (name, array) in try MLX.loadArrays(url: url) {
            guard let range = name.range(of: ".ffn.experts.") else {
                weights.append((name, array))
                continue
            }
            guard stacksExperts else { continue }
            // `<block>.ffn.experts.<expert>.<tensor>` becomes `<block>.ffn.experts.<tensor>`.
            let suffix = name[range.upperBound...]
            guard let dot = suffix.firstIndex(of: "."),
                  let expertID = Int(suffix[..<dot])
            else {
                throw DeepSeekFlashLoaderError.invalidIndex(url)
            }
            let stackedName = String(name[..<range.upperBound] + suffix[suffix.index(after: dot)...])
            experts[stackedName, default: [:]][expertID] = array
        }
        for (name, byExpert) in experts {
            weights.append((name, MLX.stacked(
                byExpert.keys.sorted().map { byExpert[$0]! }, axis: 0)))
        }
        guard !weights.isEmpty else {
            throw DeepSeekFlashLoaderError.emptyWeights(url)
        }
        try model.update(
            parameters: ModuleParameters.unflattened(weights),
            verify: .none)
        // Each shard holds whole blocks, so stacking them here bounds the peak to one shard.
        eval(weights.map(\.1))
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

    /// The shard holding every tensor of the block named by `prefix`, such as `layers.5.`.
    private static func resolveBlockURL(
        hub: HubApi,
        prefix: String,
        weightMap: [String: String],
        indexURL: URL
    ) throws -> URL {
        let shardNames = Set(weightMap.compactMap { name, shardName in
            name.hasPrefix(prefix) ? shardName : nil
        })
        guard shardNames.count == 1, let shardName = shardNames.first else {
            throw DeepSeekFlashLoaderError.invalidIndex(indexURL)
        }
        return try resolve(hub: hub, path: shardName)
    }

    private static func fileSize(_ url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw DeepSeekFlashLoaderError.fileNotFound(url)
        }
        return UInt64(size)
    }
}
