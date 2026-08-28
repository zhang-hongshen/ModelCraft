//
//  LTXVideoLoader.swift
//  ModelCraft
//

import Foundation

import Hub
import MLX
import Tokenizers

public enum LTXVideoLoaderError: Error, LocalizedError {
    case fileNotFound(URL)
    case invalidIndexFile(URL)
    case emptyWeights(URL)
    case unsupportedWeightLayout(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(url.path)"
        case .invalidIndexFile(let url):
            return "Invalid safetensors shard index: \(url.path)"
        case .emptyWeights(let url):
            return "No weights were loaded from \(url.path)"
        case .unsupportedWeightLayout(let message):
            return message
        }
    }
}

public enum LTXVideoLoader {
    public static func localDirectory(
        hub: HubApi = .default,
        configuration: LTXVideoConfiguration
    ) -> URL {
        hub.localRepoLocation(Hub.Repo(id: configuration.id))
    }

    public static func resolve(
        hub: HubApi = .default,
        configuration: LTXVideoConfiguration,
        key: LTXVideoFileKey
    ) throws -> URL {
        precondition(configuration.files.keys.contains(key), "configuration \(configuration.id) missing key: \(key)")
        return localDirectory(hub: hub, configuration: configuration)
            .appending(component: configuration.files[key]!)
    }

    public static func loadWeights(from url: URL) throws -> [String: MLXArray] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(at: url) else {
            throw LTXVideoLoaderError.fileNotFound(url)
        }

        if url.lastPathComponent.hasSuffix(".index.json") {
            let data = try Data(contentsOf: url)
            guard
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let weightMap = obj["weight_map"] as? [String: String]
            else {
                throw LTXVideoLoaderError.invalidIndexFile(url)
            }

            let weightDir = url.deletingLastPathComponent()
            var weights = [String: MLXArray]()
            for shard in Set(weightMap.values) {
                let shardURL = weightDir.appending(component: shard)
                guard fileManager.fileExists(at: shardURL) else { continue }
                let shardWeights = try MLX.loadArrays(url: shardURL)
                for (key, value) in shardWeights {
                    weights[key] = value
                }
            }
            if weights.isEmpty {
                throw LTXVideoLoaderError.emptyWeights(url)
            }
            return weights
        }

        let weights = try MLX.loadArrays(url: url)
        if weights.isEmpty {
            throw LTXVideoLoaderError.emptyWeights(url)
        }
        return weights
    }

    public static func loadTextEncoder(
        hub: HubApi = .default,
        configuration: LTXVideoConfiguration
    ) throws -> LTXVideoTextEncoder {
        let url = try resolve(hub: hub, configuration: configuration, key: .textEncoderWeights)
        let textEncoder = LTXVideoTextEncoder.t5XXL()
        let weights = LTXVideoTextEncoder.sanitize(try loadWeights(from: url))
            .mapValues { $0.asType(.bfloat16) }
            .map { ($0.key, $0.value) }
        try textEncoder.update(parameters: .unflattened(weights), verify: .none)
        return textEncoder
    }

    public static func loadTokenizer(
        hub: HubApi = .default,
        configuration: LTXVideoConfiguration
    ) async throws -> Tokenizer {
        let tokenizerURL = try resolve(hub: hub, configuration: configuration, key: .tokenizer)
        guard FileManager.default.fileExists(at: tokenizerURL) else {
            throw LTXVideoLoaderError.fileNotFound(tokenizerURL)
        }

        return try await AutoTokenizer.from(pretrained: tokenizerURL.path)
    }

    public static func loadTransformer(
        hub: HubApi = .default,
        configuration: LTXVideoConfiguration
    ) throws -> LTXVideoTransformer3DModel {
        let model = LTXVideoTransformer3DModel(configuration: configuration.transformer)
        let url = try resolve(hub: hub, configuration: configuration, key: .transformerWeights)
        let rawWeights = try loadWeights(from: url)
        let weights = LTXVideoTransformer3DModel.sanitize(rawWeights)
            .mapValues { $0.asType(.bfloat16) }
            .map { ($0.key, $0.value) }

        guard weights.contains(where: { $0.0.hasPrefix("transformer_blocks.") || $0.0.hasPrefix("proj_in.") }) else {
            throw LTXVideoLoaderError.unsupportedWeightLayout(
                "The LTX transformer checkpoint does not look like a Diffusers LTXVideoTransformer3DModel. Convert the 2B distilled single-file checkpoint to Diffusers/ModelCraft keys before loading it."
            )
        }

        try model.update(parameters: .unflattened(weights), verify: .none)
        return model
    }

    public static func loadVAE(
        hub: HubApi = .default,
        configuration: LTXVideoConfiguration
    ) throws -> LTXVideoVAE {
        let model = LTXVideoVAE(configuration: configuration.vae)
        let url = try resolve(hub: hub, configuration: configuration, key: .vaeWeights)
        let weights = LTXVideoVAE.sanitize(try loadWeights(from: url))
            .mapValues { $0.asType(.bfloat16) }
            .map { ($0.key, $0.value) }
        try model.update(parameters: .unflattened(weights), verify: .none)
        return model
    }
}

