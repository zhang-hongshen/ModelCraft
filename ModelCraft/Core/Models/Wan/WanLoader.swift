//
//  WanLoader.swift
//  ModelCraft
//
//  Created by Hongshen on 9/4/26.
//

import Foundation

import Hub
import MLX

public enum WanLoader {

    private static func resolve(hub: HubApi = HubApi(), configuration: WanConfiguration, key: WanFileKey) throws -> URL {
        precondition(
            configuration.files.keys.contains(key), "configuration \(configuration.id) missing key: \(key)")
        let repo = Hub.Repo(id: configuration.id)
        let directory = hub.localRepoLocation(repo)
        return directory.appending(component: configuration.files[key]!)
    }
    
    private static func loadWeights(
        from url: URL
    ) throws -> [String: MLXArray] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(at: url) else {
            throw WanLoaderError.fileNotFound(url)
        }
        if url.lastPathComponent.hasSuffix(".index.json") {
            let data = try Data(contentsOf: url)
            guard
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let weightMap = obj["weight_map"] as? [String: String]
            else {
                throw WanLoaderError.invalidIndexFile(url)
            }
            let weightDir = url.deletingLastPathComponent()
            let weightFiles = Set(weightMap.values)
            var weights = [String: MLXArray]()
            for wf in weightFiles {
                let shardURL = weightDir.appendingPathComponent(wf)
                
                if fileManager.fileExists(at: shardURL) {
                    let shardWeights = try MLX.loadArrays(url: shardURL)
                    for (k, v) in shardWeights {
                        weights[k] = v
                    }
                }
            }
            return weights
        } else if url.lastPathComponent.hasSuffix(".pth") {
            return [:]
        }
        return try MLX.loadArrays(url: url)
    }
    
    public static func loadDiT(hub: HubApi = HubApi(),
                               configuration: WanConfiguration) throws -> WanDiT {
        let ditParameters = configuration.ditParameters
        
        let dit = WanDiT(
            modelType: ditParameters.modelType,
            inDim: ditParameters.inDim ?? 16,
            dim: ditParameters.dim,
            ffnDim: ditParameters.ffnDim,
            numHeads: ditParameters.numHeads,
            numLayers: ditParameters.numLayers
        )
        let url = try resolve(configuration: configuration, key: .ditWeights)
        let weights = WanDiT.sanitize(try loadWeights(from: url))
        try dit.update(parameters: .unflattened(weights), verify: .none)
        return dit
    }

    public static func loadVAE(hub: HubApi = HubApi(),
                               configuration: WanConfiguration) throws -> WanVAE {
        let vae = WanVAE()
        let url = try resolve(configuration: configuration, key: .vaeWeights)
        let weights = WanVAE.sanitize(try loadWeights(from: url))
        try vae.update(parameters: .unflattened(weights), verify: .none)
        return vae
    }

    public static func loadT5Encoder(hub: HubApi = HubApi(), configuration: WanConfiguration) throws -> T5Encoder{
        let t5 = createUMT5XXLEncoder()
        let url = try resolve(configuration: configuration, key: .t5Weihghts)
        let weights = WanVAE.sanitize(try loadWeights(from: url))
        try t5.update(parameters: .unflattened(weights), verify: .none)
        return t5
    }

    public static func loadTokenizer(hub: HubApi = HubApi(), configuration: WanConfiguration) async throws -> T5Tokenizer {
        let url = try resolve(configuration: configuration, key: .tokenizer)
        return try await T5Tokenizer(tokenizerURL: url)
    }

    public static func loadCLIP(hub: HubApi = HubApi(), configuration: WanConfiguration) throws -> CLIPVisionEncoder {
        let clip = CLIPVisionEncoder()
        let url = try resolve(configuration: configuration, key: .clipWeights)
        let weights = CLIPVisionEncoder.sanitize(try loadWeights(from: url))
        try clip.update(parameters: .unflattened(weights), verify: .none)
        return clip
    }
}

