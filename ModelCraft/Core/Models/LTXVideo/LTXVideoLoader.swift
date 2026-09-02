//
//  LTXVideoLoader.swift
//  ModelCraft
//

import Foundation

import Hub
import MLX
import MLXNN
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

    private static func weightURLs(from url: URL) throws -> [URL] {
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
            return try Set(weightMap.values).sorted().map { shard in
                let shardURL = weightDir.appending(component: shard)
                guard fileManager.fileExists(at: shardURL) else {
                    throw LTXVideoLoaderError.fileNotFound(shardURL)
                }
                return shardURL
            }
        }

        return [url]
    }

    public static func loadWeights(from url: URL) throws -> [String: MLXArray] {
        var weights = [String: MLXArray]()
        for weightsURL in try weightURLs(from: url) {
            for (key, value) in try MLX.loadArrays(url: weightsURL) {
                weights[key] = value
            }
        }
        if weights.isEmpty {
            throw LTXVideoLoaderError.emptyWeights(url)
        }
        return weights
    }

    @discardableResult
    private static func loadWeights(
        from url: URL,
        into model: Module,
        sanitize: ([String: MLXArray]) -> [String: MLXArray],
        quantization: LTXVideoQuantization? = nil
    ) throws -> Set<String> {
        var loadedKeys = Set<String>()

        for weightsURL in try weightURLs(from: url) {
            let weights = sanitize(try MLX.loadArrays(url: weightsURL))
                .map { ($0.key, $0.value.asType(.bfloat16)) }
            guard !weights.isEmpty else { continue }

            loadedKeys.formUnion(weights.map(\.0))
            try model.update(parameters: .unflattened(weights), verify: .none)

            if let quantization {
                let loadedWeightPaths = Set(weights.compactMap { key, _ in
                    key.hasSuffix(".weight") ? String(key.dropLast(".weight".count)) : nil
                })
                quantize(
                    model: model,
                    groupSize: quantization.groupSize,
                    bits: quantization.bits,
                    filter: { path, _ in loadedWeightPaths.contains(path) })
                for (path, module) in model.leafModules().flattened()
                where loadedWeightPaths.contains(path) {
                    eval(module)
                }
                Memory.clearCache()
            }
        }

        if loadedKeys.isEmpty {
            throw LTXVideoLoaderError.emptyWeights(url)
        }
        return loadedKeys
    }

    public static func loadTextEncoder(
        hub: HubApi = .default,
        configuration: LTXVideoConfiguration
    ) throws -> LTXVideoTextEncoder {
        try loadTextEncoder(
            hub: hub,
            configuration: configuration,
            quantization: nil)
    }

    static func loadTextEncoder(
        hub: HubApi = .default,
        configuration: LTXVideoConfiguration,
        quantization: LTXVideoQuantization?
    ) throws -> LTXVideoTextEncoder {
        let url = try resolve(hub: hub, configuration: configuration, key: .textEncoderWeights)
        let textEncoder = LTXVideoTextEncoder.t5XXL()
        try loadWeights(
            from: url,
            into: textEncoder,
            sanitize: LTXVideoTextEncoder.sanitize,
            quantization: quantization)
        eval(textEncoder)
        Memory.clearCache()
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
        try loadTransformer(
            hub: hub,
            configuration: configuration,
            quantization: nil)
    }

    static func loadTransformer(
        hub: HubApi = .default,
        configuration: LTXVideoConfiguration,
        quantization: LTXVideoQuantization?
    ) throws -> LTXVideoTransformer3DModel {
        let model = LTXVideoTransformer3DModel(configuration: configuration.transformer)
        let url = try resolve(hub: hub, configuration: configuration, key: .transformerWeights)
        let loadedKeys = try loadWeights(
            from: url,
            into: model,
            sanitize: LTXVideoTransformer3DModel.sanitize,
            quantization: quantization)

        guard loadedKeys.contains(where: {
            $0.hasPrefix("transformer_blocks.") || $0.hasPrefix("proj_in.")
        }) else {
            throw LTXVideoLoaderError.unsupportedWeightLayout(
                "The LTX transformer checkpoint does not look like a Diffusers LTXVideoTransformer3DModel. Convert the 2B distilled single-file checkpoint to Diffusers/ModelCraft keys before loading it."
            )
        }

        eval(model)
        Memory.clearCache()
        return model
    }

    public static func loadVAE(
        hub: HubApi = .default,
        configuration: LTXVideoConfiguration
    ) throws -> LTXVideoVAE {
        let model = LTXVideoVAE(configuration: configuration.vae)
        let url = try resolve(hub: hub, configuration: configuration, key: .vaeWeights)
        try loadWeights(
            from: url,
            into: model,
            sanitize: LTXVideoVAE.sanitize)
        eval(model)
        Memory.clearCache()
        return model
    }
}
