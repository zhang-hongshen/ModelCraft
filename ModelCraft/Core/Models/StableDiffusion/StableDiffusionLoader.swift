// Copyright © 2024 Apple Inc.

import Foundation
import Hub
import MLX
import MLXNN


public class StableDiffusionLoader {
    
    private static func loadWeights(
        url: URL, model: Module, mapper: (String, MLXArray) -> [(String, MLXArray)], dType: DType
    ) throws {
        let weights = try loadArrays(url: url).flatMap { mapper($0.key, $0.value.asType(dType)) }

        // Note: not using verifier because some shapes change upon load
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: .none)
    }

    // MARK: - Loading

    private static func resolve(hub: HubApi, configuration: StableDiffusionConfiguration, key: FileKey) -> URL {
        precondition(
            configuration.files[key] != nil, "configuration \(configuration.id) missing key: \(key)")
        let repo = Hub.Repo(id: configuration.id)
        let directory = hub.localRepoLocation(repo)
        return directory.appending(component: configuration.files[key]!)
    }

    static func loadConfiguration<T: Decodable>(
        hub: HubApi, configuration: StableDiffusionConfiguration, key: FileKey, type: T.Type
    ) throws -> T {
        let url = resolve(hub: hub, configuration: configuration, key: key)
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    static func loadUnet(hub: HubApi, configuration: StableDiffusionConfiguration, dType: DType) throws
        -> StableDiffusionUNet
    {
        let unetConfiguration = try loadConfiguration(
            hub: hub, configuration: configuration, key: .unetConfig, type: UNetConfiguration.self)
        let model = StableDiffusionUNet(configuration: unetConfiguration)

        let weightsURL = resolve(hub: hub, configuration: configuration, key: .unetWeights)
        try loadWeights(url: weightsURL, model: model, mapper: unetRemap, dType: dType)

        return model
    }

    static func loadTextEncoder(
        hub: HubApi, configuration: StableDiffusionConfiguration,
        configKey: FileKey = .textEncoderConfig, weightsKey: FileKey = .textEncoderWeights, dType: DType
    ) throws -> StableDiffusionTextEncoder {
        let clipConfiguration = try loadConfiguration(
            hub: hub, configuration: configuration, key: configKey,
            type: CLIPTextModelConfiguration.self)
        let model = StableDiffusionTextEncoder(configuration: clipConfiguration)

        let weightsURL = resolve(hub: hub, configuration: configuration, key: weightsKey)
        try loadWeights(url: weightsURL, model: model, mapper: clipRemap, dType: dType)

        return model
    }

    static func loadAutoEncoder(hub: HubApi, configuration: StableDiffusionConfiguration, dType: DType) throws
        -> Autoencoder
    {
        let autoEncoderConfiguration = try loadConfiguration(
            hub: hub, configuration: configuration, key: .vaeConfig, type: AutoencoderConfiguration.self
        )
        let model = Autoencoder(configuration: autoEncoderConfiguration)

        let weightsURL = resolve(hub: hub, configuration: configuration, key: .vaeWeights)
        try loadWeights(url: weightsURL, model: model, mapper: vaeRemap, dType: dType)

        return model
    }

    static func loadDiffusionConfiguration(hub: HubApi, configuration: StableDiffusionConfiguration) throws
        -> DiffusionConfiguration
    {
        try loadConfiguration(
            hub: hub, configuration: configuration, key: .diffusionConfig,
            type: DiffusionConfiguration.self)
    }

    // MARK: - Tokenizer

    static func loadTokenizer(
        hub: HubApi, configuration: StableDiffusionConfiguration,
        vocabulary: FileKey = .tokenizerVocabulary, merges: FileKey = .tokenizerMerges
    ) throws -> StableDiffusionTokenizer {
        let vocabularyURL = resolve(hub: hub, configuration: configuration, key: vocabulary)
        let mergesURL = resolve(hub: hub, configuration: configuration, key: merges)

        let vocabulary = try JSONDecoder().decode(
            [String: Int].self, from: Data(contentsOf: vocabularyURL))
        let merges = try String(contentsOf: mergesURL)
            .components(separatedBy: .newlines)
            // first line is a comment
            .dropFirst()
            .filter { !$0.isEmpty }

        return StableDiffusionTokenizer(merges: merges, vocabulary: vocabulary)
    }

}
