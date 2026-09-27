//
//  H3Loader.swift
//  ModelCraft
//
//  Created by Hongshen on 27/8/26.
//

import Foundation
import Hub
import MLX
import MLXNN


public enum H3LoaderError: Error, LocalizedError {
    case missingFileKey(H3FileKey)
    case fileNotFound(URL)
    case invalidTokenizerVocabulary(URL)
    case invalidIndex(URL)
    case missingShard(URL)
    case missingLayer(Int)
    case missingTransformerBlock(Int)
    case missingTensor(String)
    case duplicateTensor(String)
    case emptyWeights(URL)
    case missingConfigValue(String)

    public var errorDescription: String? {
        switch self {
        case .missingFileKey(let key):
            return "MiniMax H3 configuration is missing file key: \(key.rawValue)"
        case .fileNotFound(let url):
            return "MiniMax H3 file is not available at: \(url.path)"
        case .invalidTokenizerVocabulary(let url):
            return "MiniMax H3 tokenizer vocabulary is not a string-to-integer map: \(url.path)"
        case .invalidIndex(let url):
            return "Invalid SafeTensors shard index: \(url.path)"
        case .missingShard(let url):
            return "SafeTensors shard is missing: \(url.path)"
        case .missingLayer(let index):
            return "No SafeTensors shard holds layer \(index)"
        case .missingTransformerBlock(let index):
            return "No SafeTensors shard sequence completes Transformer block \(index)"
        case .missingTensor(let name):
            return "MiniMax H3 weights have no tensor named \(name)"
        case .duplicateTensor(let name):
            return "Tensor appears in more than one SafeTensors shard: \(name)"
        case .emptyWeights(let url):
            return "No weights were loaded from \(url.path)"
        case .missingConfigValue(let name):
            return "MiniMax H3 configuration has no value for \(name)"
        }
    }
}

public enum H3Loader {
    /// Resolves a configured file inside HubApi's local snapshot.
    ///
    /// HubApi owns cache lookup and download. This resolver only translates
    /// the Configuration key into the materialized local URL after download.
    static func resolve(
        hub: HubApi,
        configuration: H3Configuration,
        key: H3FileKey
    ) throws -> URL {
        guard let path = configuration.files[key] else {
            throw H3LoaderError.missingFileKey(key)
        }
        let url = hub.localRepoLocation(Hub.Repo(id: configuration.id))
            .appending(component: path)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw H3LoaderError.fileNotFound(url)
        }
        return url
    }

    /// Loads a single SafeTensors file or all shards referenced by its
    /// `.index.json` file.
    ///
    /// This is the general whole-checkpoint weight path. Component loaders use it
    /// when they need one file or a filtered set across all shards; streamed block
    /// stacks open their current shard directly instead.
    ///
    /// The map it returns is cheap and lazy. MLX holds the file open and gives
    /// each tensor its own byte offset, so a returned array costs a descriptor
    /// entry until something evaluates it, and only the tensors that are actually
    /// used ever reach memory.
    static func loadWeights(from url: URL) throws -> [String: MLXArray] {
        var output: [String: MLXArray] = [:]
        for shard in try shardURLs(for: url) {
            for (name, array) in try MLX.loadArrays(url: shard) {
                guard output[name] == nil else {
            throw H3LoaderError.duplicateTensor(name)
                }
                output[name] = array
            }
        }
        guard !output.isEmpty else {
            throw H3LoaderError.emptyWeights(url)
        }
        return output
    }

    /// The file holding layer `index` of a stack, from the checkpoint's own index.
    ///
    /// The checkpoint names every tensor and the shard it lives in, so finding a
    /// layer is a scan of that map. A single-file checkpoint has no index: every
    /// layer answers with that file, which is where the `count` comes in.
    ///
    /// The index is re-read on each call. It is a few tens of KB of JSON and a
    /// walk reads it once per layer, which the weight reads themselves dwarf.
    private static func shardURL(
        holding index: Int,
        of url: URL,
        count: Int,
        index indexOfTensor: (String) -> Int?
    ) throws -> URL {
        let map = try weightMap(for: url)
        if map.isEmpty {
            guard index >= 0, index < count else { throw H3LoaderError.missingLayer(index) }
            return url
        }
        for (name, file) in map where indexOfTensor(name) == index {
            return url.deletingLastPathComponent().appending(component: file)
        }
        throw H3LoaderError.missingLayer(index)
    }

    /// Reads exactly the tensors of one layer, leaving the rest of its shard
    /// unread.
    ///
    /// MLX gives every tensor in a SafeTensors file its own byte offset, so this
    /// costs the shard's header plus the layer, not the shard. The map handed to
    /// `makeLayer` is dropped as soon as it returns, and a layer that keeps only the
    /// arrays it read gives the shard back with it.
    private static func loadLayer<Layer>(
        _ index: Int,
        of url: URL,
        count: Int,
        indexOfTensor: (String) -> Int?,
        makeLayer: ([String: MLXArray]) throws -> Layer
    ) throws -> Layer {
        let weights = try loadWeights(
            from: try shardURL(holding: index, of: url, count: count, index: indexOfTensor))
        return try makeLayer(weights)
    }

    /// Loads one layer of the text encoder's language stack.
    ///
    /// The caller holds whichever layers it has room for; this reads only the one
    /// asked for. See ``H3TextEncoder/encode(embeds:positionIds:visualSpans:deepstack:)``.
    ///
    /// The layer is declared and then filled from the shard's own names, so there
    /// is one construction path and a tensor cannot be wired to the wrong matrix.
    ///
    /// Both directions are checked, as they are for the DiT: a declared parameter
    /// that does not arrive would leave its placeholder in place, and this layer
    /// is one of fifty that nothing else looks at afterwards.
    static func loadTextEncoderLayer(
        index: Int,
        url: URL,
        prefix: String,
        config: H3TextEncoderConfiguration
    ) throws -> H3TextEncoderLayer {
        try loadLayer(
            index, of: url, count: config.numLayers,
            indexOfTensor: { name in
                for layerPrefix in ["model.language_model.layers.", "model.layers."] {
                    guard name.hasPrefix(layerPrefix) else { continue }
                    let rest = name.dropFirst(layerPrefix.count)
                    guard let dot = rest.firstIndex(of: ".") else { return nil }
                    return Int(rest[rest.startIndex ..< dot])
                }
                return nil
            }
        ) { tensors in
            let root = "\(prefix)layers.\(index)."
            var parameters: [String: MLXArray] = [:]
            for (name, array) in tensors where name.hasPrefix(root) {
                parameters[String(name.dropFirst(root.count))] = array
            }
            let layer = H3TextEncoderLayer(config: config)
            try layer.update(
                parameters: ModuleParameters.unflattened(parameters),
                verify: [.none])
            return layer
        }
    }

    /// Walks the Omni Transformer's blocks one SafeTensors file at a time.
    ///
    /// A shard normally completes several consecutive blocks. If the checkpoint
    /// splits one block across a file boundary, its first tensors remain in
    /// `pending` until the next shard supplies the rest. The caller runs every
    /// completed block and evaluates its hidden state before this function moves
    /// on, so the current shard can leave memory before the next one opens.
    static func loadTransformerBlocks(
        url: URL,
        config: H3Configuration,
        body: ([H3OmniTransformerBlock]) throws -> Void
    ) throws {
        let weightMap = try weightMap(for: url)
        let shards = try shardURLs(for: url)
        var expectedNames = [Int: Set<String>]()

        if !weightMap.isEmpty {
            for name in weightMap.keys {
                guard let index = transformerBlockIndex(name) else { continue }
                expectedNames[index, default: []].insert(name)
            }
        }

        var pending = [Int: [String: MLXArray]]()
        var nextBlock = 0

        for shard in shards {
            var blocks = [H3OmniTransformerBlock]()
            do {
                let tensors = try MLX.loadArrays(url: shard)
                if weightMap.isEmpty && expectedNames.isEmpty {
                    for name in tensors.keys {
                        guard let index = transformerBlockIndex(name) else { continue }
                        expectedNames[index, default: []].insert(name)
                    }
                }

                for (name, array) in tensors {
                    guard let index = transformerBlockIndex(name) else { continue }
                    guard pending[index]?[name] == nil else {
                        throw H3LoaderError.duplicateTensor(name)
                    }
                    pending[index, default: [:]][name] = array
                }

                while nextBlock < config.numTransformerBlocks {
                    guard let expected = expectedNames[nextBlock],
                          let parameters = pending[nextBlock],
                          Set(parameters.keys).isSuperset(of: expected)
                    else { break }
                    blocks.append(try makeTransformerBlock(
                        index: nextBlock,
                        tensors: parameters,
                        config: config))
                    pending[nextBlock] = nil
                    nextBlock += 1
                }
            }
            if !blocks.isEmpty {
                try body(blocks)
            }
            blocks.removeAll(keepingCapacity: false)
            Memory.clearCache()
        }

        guard nextBlock == config.numTransformerBlocks else {
            throw H3LoaderError.missingTransformerBlock(nextBlock)
        }
    }

    private static func transformerBlockIndex(_ name: String) -> Int? {
        let prefix = "transformer_blocks."
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        guard let dot = rest.firstIndex(of: ".") else { return nil }
        return Int(rest[rest.startIndex ..< dot])
    }

    private static func makeTransformerBlock(
        index: Int,
        tensors: [String: MLXArray],
        config: H3Configuration
    ) throws -> H3OmniTransformerBlock {
        let root = "transformer_blocks.\(index)."
        var parameters: [String: MLXArray] = [:]
        for (name, array) in tensors where name.hasPrefix(root) {
            let key = String(name.dropFirst(root.count))
                .replacingOccurrences(of: ".attn.to_out.0.", with: ".attn.toOut.")
                .replacingOccurrences(of: ".ff.net.0.proj.", with: ".ff.w1.")
                .replacingOccurrences(of: ".ff.net.2.", with: ".ff.w2.")
                .replacingOccurrences(of: ".downsamplers.0.", with: ".downsamplers.")
            parameters[key] = array
        }
        let block = H3OmniTransformerBlock(config: config)
        try block.update(
            parameters: ModuleParameters.unflattened(parameters),
            verify: [.none])
        return block
    }

    /// Loads one block of the video VAE's decoder stack.
    ///
    /// Declared and then filled from the slice of the file whose names start
    /// `decoder.transformer_blocks.<index>.`, so there is one construction path
    /// and a tensor cannot be wired to the wrong matrix. Both directions are
    /// checked: a mis-wired block would not fail to load, it would produce a
    /// plausible-looking wrong frame.
    static func loadVisualVAEDecoderLayer(
        index: Int,
        url: URL,
        config: H3VideoVAEConfiguration
    ) throws -> VisualVAEDecoderLayer {
        try loadLayer(
            index, of: url, count: config.decoderLayers,
            indexOfTensor: { name in
                let prefix = "decoder.transformer_blocks."
                guard name.hasPrefix(prefix) else { return nil }
                let rest = name.dropFirst(prefix.count)
                guard let dot = rest.firstIndex(of: ".") else { return nil }
                return Int(rest[rest.startIndex ..< dot])
            }
        ) { tensors in
            let root = "decoder.transformer_blocks.\(index)."
            var parameters: [String: MLXArray] = [:]
            for (name, array) in tensors where name.hasPrefix(root) {
                let key = String(name.dropFirst(root.count))
                    .replacingOccurrences(of: ".attn.to_out.0.", with: ".attn.toOut.")
                    .replacingOccurrences(of: ".ff.net.0.proj.", with: ".ff.w1.")
                    .replacingOccurrences(of: ".ff.net.2.", with: ".ff.w2.")
                    .replacingOccurrences(of: ".downsamplers.0.", with: ".downsamplers.")
                parameters[key] = array
            }
            let model = VisualVAEDecoderLayer(config: config)
            try model.update(
                parameters: ModuleParameters.unflattened(parameters),
                verify: [.none])
            return model
        }
    }

    /// Loads the Omni Transformer's root weights into its declared root modules.
    ///
    /// 1.72 GB of refiner, time embedder, output layer and projections, held once
    /// per render rather than read once per step. The 50 Transformer blocks are
    /// not loaded here — they are 64.56 GB and are streamed by SafeTensors file
    /// in ``H3OmniTransformer/runStack(_:)``.
    ///
    /// The root modules are filled by name; the names need no translating, since
    /// the checkpoint already spells them the way the declaration reads. Both
    /// directions are checked: a parameter the declaration has and the
    /// checkpoint does not is named, and so is one whose shape disagrees. The
    /// Transformer calls this from its initializer. Its block stack is loaded by
    /// ``loadTransformerBlocks(url:config:body:)`` while sampling.
    static func loadRoot(
        into transformer: H3OmniTransformer,
        hub: HubApi,
        configuration: H3Configuration
    ) throws {
        let url = try resolve(hub: hub, configuration: configuration, key: .transformerWeights)
        let weights = try loadWeights(
            from: url,
            matching: { name in
                let prefix = "transformer_blocks."
                guard name.hasPrefix(prefix) else { return true }
                let rest = name.dropFirst(prefix.count)
                guard let dot = rest.firstIndex(of: ".") else { return true }
                return Int(rest[rest.startIndex ..< dot]) == nil
            })

        // The refiner's blocks carry the export's list indices too, so the whole
        // map is folded, not just each block's slice.
        try transformer.update(
            parameters: ModuleParameters.unflattened(
                weights.reduce(into: [String: MLXArray]()) {
                    let key = $1.key
                        .replacingOccurrences(of: ".attn.to_out.0.", with: ".attn.toOut.")
                        .replacingOccurrences(of: ".ff.net.0.proj.", with: ".ff.w1.")
                        .replacingOccurrences(of: ".ff.net.2.", with: ".ff.w2.")
                        .replacingOccurrences(
                            of: ".downsamplers.0.", with: ".downsamplers.")
                    $0[key] = $1.value
                }),
            verify: [.none])
    }

    /// Loads the video VAE, both directions.
    ///
    /// One read of the file fills the whole tree after this loader re-keys the
    /// encoder tensors. The decoder's 36-block stack is the one
    /// part left empty — it is 9.669 GB of the file's 10.42 GB and
    /// ``H3VisualVAEDecoder/callAsFunction(_:)`` reads each block as the decode
    /// reaches it.
    ///
    /// The latent normalization comes from the config file rather than the
    /// weights: this export keeps `latents_mean` and `latents_std` there, one
    /// value per latent channel, and the decoder cannot denormalize without them.
    ///
    /// Both directions are checked, and that is deliberate: a parameter the
    /// declaration has and the checkpoint does not is named, and so is one whose
    /// shape disagrees. An unfilled parameter would otherwise leave its
    /// placeholder in place and decode a plausible-looking wrong frame.
    static func loadVisualVAE(
        hub: HubApi,
        configuration: H3Configuration
    ) throws -> H3VisualVAE {
        var configuration = configuration
        configuration.videoVAE = try loadVideoVAEConfig(hub: hub, configuration: configuration)
        let weights = try loadWeights(from: try resolve(
            hub: hub, configuration: configuration, key: .videoVAEWeights))
        let model = H3VisualVAE(hub: hub, configuration: configuration)

        var local: [String: MLXArray] = [:]
        for (name, array) in weights {
            if name.hasPrefix("encoder.") || name.hasPrefix("quant_conv.") {
                let key = (name.hasPrefix("encoder.")
                           ? String(name.dropFirst("encoder.".count))
                           : name)
                    .replacingOccurrences(of: ".attn.to_out.0.", with: ".attn.toOut.")
                    .replacingOccurrences(of: ".ff.net.0.proj.", with: ".ff.w1.")
                    .replacingOccurrences(of: ".ff.net.2.", with: ".ff.w2.")
                    .replacingOccurrences(of: ".downsamplers.0.", with: ".downsamplers.")
                local["encoder.\(key)"] = array
                continue
            }

            let blockPrefix = "decoder.transformer_blocks."
            let rest = name.dropFirst(blockPrefix.count)
            let isDecoderBlock = name.hasPrefix(blockPrefix)
                && rest.firstIndex(of: ".").map {
                    Int(rest[rest.startIndex ..< $0]) != nil
                } == true
            if !isDecoderBlock {
                local[name] = array
            }
        }
        try model.update(
            parameters: ModuleParameters.unflattened(local),
            verify: [.none])
        return model
    }

    /// The configuration with the video VAE's dimensions read out of its own
    /// `config.json` and stored in it.
    static func loadVideoVAEConfig(
        hub: HubApi,
        configuration: H3Configuration
    ) throws -> H3VideoVAEConfiguration {
        let url = try resolve(hub: hub, configuration: configuration, key: .videoVAEConfig)
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw H3LoaderError.missingConfigValue(url.lastPathComponent)
        }
        var c = H3VideoVAEConfiguration()

        func ints(_ key: String) -> [Int]? {
            (object[key] as? [NSNumber])?.map(\.intValue)
        }
        func floats(_ key: String) -> [Float]? {
            (object[key] as? [NSNumber])?.map(\.floatValue)
        }
        func int(_ key: String) -> Int? { (object[key] as? NSNumber)?.intValue }
        func float(_ key: String) -> Float? { (object[key] as? NSNumber)?.floatValue }

        c.blockOutChannels = ints("block_out_channels") ?? c.blockOutChannels
        c.layersPerBlock = int("layers_per_block") ?? c.layersPerBlock
        c.latentChannels = int("latent_channels") ?? c.latentChannels
        c.normGroups = int("norm_num_groups") ?? c.normGroups
        c.normEps = float("norm_eps") ?? c.normEps
        c.spatialDownsampleFactors =
            ints("spatial_downsample_factors") ?? c.spatialDownsampleFactors
        c.temporalDownsampleFactors =
            ints("temporal_downsample_factors") ?? c.temporalDownsampleFactors
        c.inChannels = int("in_channels") ?? c.inChannels
        c.outChannels = int("out_channels") ?? c.outChannels
        c.clipLength = int("clip_length") ?? c.clipLength
        c.tokenDrop = int("token_drop") ?? c.tokenDrop

        c.decoderLayers = int("decoder_num_layers") ?? c.decoderLayers
        c.decoderAttentionHeads = int("decoder_num_attention_heads")
            ?? c.decoderAttentionHeads
        c.decoderAttentionHeadDim = int("decoder_attention_head_dim")
            ?? c.decoderAttentionHeadDim
        c.decoderRegisterTokens = int("decoder_num_register_tokens")
            ?? c.decoderRegisterTokens
        c.decoderFFNMultiplier = int("decoder_ffn_mult") ?? c.decoderFFNMultiplier
        c.decoderRopeTheta = float("decoder_rope_theta") ?? c.decoderRopeTheta
        c.decoderRopeDimRatio = float("decoder_rope_dim_ratio") ?? c.decoderRopeDimRatio
        c.decoderNormEps = float("decoder_norm_eps") ?? c.decoderNormEps

        guard let mean = floats("latents_mean"), let std = floats("latents_std") else {
            throw H3LoaderError.missingConfigValue(
                "latents_mean/latents_std in \(url.lastPathComponent)")
        }
        c.latentsMean = mean
        c.latentsStd = std
        return c
    }

    /// Loads the audio VAE, both directions.
    ///
    /// 0.61 GB in one file, read whole. Splitting it into blocks would cost more
    /// than it saves — see ``H3RuntimeProfile``.
    ///
    /// One read fills both directions after this loader re-keys and prefixes each
    /// half. Both directions are checked, as they are for the video VAE — see
    /// ``loadVisualVAE(hub:configuration:)``.
    static func loadAudioVAE(
        hub: HubApi,
        configuration: H3Configuration
    ) throws -> H3AudioVAE {
        var configuration = configuration
        configuration.audioVAE = try loadAudioVAEConfig(
            hub: hub, configuration: configuration)
        let weights = try loadWeights(from: try resolve(
            hub: hub, configuration: configuration, key: .audioVAEWeights))
        let vae = H3AudioVAE(configuration: configuration)

        var local: [String: MLXArray] = [:]
        for (name, array) in weights {
            if name.hasPrefix("decoder.") {
                let parts = String(name.dropFirst("decoder.".count))
                    .split(separator: ".").map(String.init)
                guard let head = parts.first else { continue }
                let key: String
                switch head {
                case "conv_pre", "conv_post", "activation_post", "resblocks":
                    let localHead = [
                        "conv_pre": "convPre",
                        "conv_post": "convPost",
                        "activation_post": "activationPost",
                        "resblocks": "resblocks",
                    ][head]!
                    let tail = parts.dropFirst().joined(separator: ".")
                    key = tail.isEmpty ? localHead : "\(localHead).\(tail)"
                case "ups":
                    guard parts.count >= 4 else { continue }
                    key = "ups.\(parts[1])." + parts.dropFirst(3).joined(separator: ".")
                default:
                    continue
                }
                local["decoder.\(key)"] = array
                continue
            }

            if name.hasPrefix("pre_block.") || name.hasPrefix("mean_proj.") {
                let parts = name.split(separator: ".").map(String.init)
                let head = name.hasPrefix("pre_block.") ? "preBlock" : "meanProj"
                let tail = parts.dropFirst().joined(separator: ".")
                let key = tail.isEmpty ? head : "\(head).\(tail)"
                local["encoder.\(key)"] = array
                continue
            }

            if name.hasPrefix("encoder.") {
                let parts = name.split(separator: ".").map(String.init)
                guard parts.count >= 3, parts[1] == "block" else { continue }
                let key: String
                switch parts[2] {
                case "0", "6", "7":
                    let head = ["0": "convIn", "6": "actOut", "7": "convOut"][parts[2]]!
                    let tail = parts.dropFirst(3).joined(separator: ".")
                    key = tail.isEmpty ? head : "\(head).\(tail)"
                case "1", "2", "3", "4", "5":
                    guard parts.count >= 5, parts[3] == "block",
                          let level = Int(parts[2])
                    else { continue }
                    let block = "blocks.\(level - 1)"
                    switch parts[4] {
                    case "0", "1", "2":
                        guard parts.count >= 7, parts[5] == "block",
                              let unit = Int(parts[4]),
                              let leaf = ["0": "act1", "1": "conv1",
                                          "2": "act2", "3": "conv2"][parts[6]]
                        else { continue }
                        let head = "\(block).units.\(unit).\(leaf)"
                        let tail = parts.dropFirst(7).joined(separator: ".")
                        key = tail.isEmpty ? head : "\(head).\(tail)"
                    case "3", "4":
                        let head = "\(block).\(parts[4] == "3" ? "act" : "down")"
                        let tail = parts.dropFirst(5).joined(separator: ".")
                        key = tail.isEmpty ? head : "\(head).\(tail)"
                    default:
                        continue
                    }
                default:
                    continue
                }
                local["encoder.\(key)"] = array
                continue
            }

            if name.hasPrefix("dec_in_proj.") {
                local[name] = array
            }
        }
        try vae.update(
            parameters: ModuleParameters.unflattened(local),
            verify: [.none])
        return vae
    }

    /// The configuration with the audio VAE's dimensions read out of its own
    /// `config.json` and stored in it.
    static func loadAudioVAEConfig(
        hub: HubApi,
        configuration: H3Configuration
    ) throws -> H3AudioVAEConfiguration {
        let url = try resolve(hub: hub, configuration: configuration, key: .audioVAEConfig)
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw H3LoaderError.missingConfigValue(url.lastPathComponent)
        }
        var c = H3AudioVAEConfiguration()

        func ints(_ key: String) -> [Int]? {
            (object[key] as? [NSNumber])?.map(\.intValue)
        }
        func floats(_ key: String) -> [Float]? {
            (object[key] as? [NSNumber])?.map(\.floatValue)
        }
        func int(_ key: String) -> Int? { (object[key] as? NSNumber)?.intValue }
        func nestedInts(_ key: String) -> [[Int]]? {
            (object[key] as? [[NSNumber]])?.map { $0.map(\.intValue) }
        }

        c.encoderDim = int("encoder_dim") ?? c.encoderDim
        c.encoderRates = ints("encoder_rates") ?? c.encoderRates
        c.latentDim = int("latent_dim") ?? c.latentDim
        c.latentChannels = int("latent_channels") ?? c.latentChannels
        c.decoderDim = int("decoder_dim") ?? c.decoderDim
        c.decoderRates = ints("decoder_rates") ?? c.decoderRates
        c.decoderKernelSizes = ints("decoder_kernel_sizes") ?? c.decoderKernelSizes
        c.numAttentionHeads = int("num_attention_heads") ?? c.numAttentionHeads
        c.resblockKernelSizes = ints("resblock_kernel_sizes") ?? c.resblockKernelSizes
        c.resblockDilationSizes = nestedInts("resblock_dilation_sizes")
            ?? c.resblockDilationSizes
        c.samplingRate = int("sampling_rate") ?? c.samplingRate

        guard let mean = floats("latents_mean"), let std = floats("latents_std") else {
            throw H3LoaderError.missingConfigValue(
                "latents_mean/latents_std in \(url.lastPathComponent)")
        }
        c.latentsMean = mean
        c.latentsStd = std
        return c
    }

    /// Loads the composed H3 Encoder.
    ///
    /// Which of the two shapes comes back is the machine's profile, not the
    /// caller's: a machine that reads components whole gets both halves built
    /// here, and any other gets the container the halves fill themselves from
    /// when a render first asks for one — see ``H3Encoder``.
    ///
    /// Building a half is not the same as paging it in. What the eager path
    /// actually reads is the checkpoint's headers and the 2.75 GB of tensors
    /// outside the language stack; the 62.41 GB behind those tensors is still read
    /// a layer at a time as the pass reaches it.
    static func loadEncoder(
        hub: HubApi,
        configuration: H3Configuration
    ) throws -> H3Encoder {
        guard configuration.runtimeProfile.loadsComponentsEagerly else {
            return H3Encoder(hub: hub, configuration: configuration)
        }

        // One read of the non-layer tensors, then both halves off it: a
        // reference-conditioned render reaches the vision tower to encode a
        // reference and the language stack to encode the prompt it belongs to.
        let globals = try loadEncoderGlobals(hub: hub, configuration: configuration)
        return H3Encoder(
            hub: hub,
            configuration: configuration,
            globals: globals,
            textEncoder: try loadTextEncoder(
                globals: globals, hub: hub, configuration: configuration),
            visionEncoder: try loadVisionEncoder(globals: globals))
    }

    /// Loads the tokenizer out of the checkpoint's own `vocab.json`, `merges.txt`
    /// and `tokenizer_config.json`.
    static func loadTokenizer(
        hub: HubApi,
        configuration: H3Configuration
    ) throws -> H3Tokenizer {
        let vocabularyURL = try resolve(
            hub: hub, configuration: configuration, key: .tokenizerVocabulary)
        let mergesURL = try resolve(
            hub: hub, configuration: configuration, key: .tokenizerMerges)
        guard let vocabularyData = try? Data(contentsOf: vocabularyURL) else {
            throw H3LoaderError.fileNotFound(vocabularyURL)
        }
        guard let merges = try? String(contentsOf: mergesURL, encoding: .utf8) else {
            throw H3LoaderError.fileNotFound(mergesURL)
        }
        guard let vocabulary = try JSONSerialization.jsonObject(with: vocabularyData)
            as? [String: Int]
        else {
            throw H3LoaderError.invalidTokenizerVocabulary(vocabularyURL)
        }
        let tokenizerConfigURL = try resolve(hub: hub, configuration: configuration, key: .tokenizerConfig)
        let tokenizerConfigData = try Data(contentsOf: tokenizerConfigURL)
        return H3Tokenizer(
            vocab: vocabulary,
            merges: merges,
            tokenizerConfigData: tokenizerConfigData)
    }

    /// Every tensor of the `text_encoder` checkpoint that is not a language
    /// layer: the embedding table and the vision tower. 2.75 GB, read once and
    /// handed to both halves — see ``loadTextEncoder(globals:hub:configuration:)``
    /// and ``loadVisionEncoder(globals:)``.
    ///
    /// `lm_head` is dropped rather than handed on: nothing in the conditioning
    /// path reads it, and a text encoder has no next-token prediction to want it
    /// for.
    static func loadEncoderGlobals(
        hub: HubApi,
        configuration: H3Configuration
    ) throws -> [String: MLXArray] {
        var weights = try loadWeights(
            from: try resolve(
                hub: hub, configuration: configuration, key: .textEncoderWeights),
            matching: { name in
                for prefix in ["model.language_model.layers.", "model.layers."] {
                    guard name.hasPrefix(prefix) else { continue }
                    let rest = name.dropFirst(prefix.count)
                    guard let dot = rest.firstIndex(of: ".") else { return true }
                    return Int(rest[rest.startIndex ..< dot]) == nil
                }
                return true
            })
        weights["lm_head.weight"] = nil
        return weights
    }

    /// The language half: the embedding table and the layer stack's tensor names.
    ///
    /// The language layers themselves are not here — they are 62.41 GB and
    /// ``H3TextEncoder/encode(embeds:positionIds:visualSpans:deepstack:)``
    /// reads each one as the pass reaches it.
    static func loadTextEncoder(
        globals: [String: MLXArray],
        hub: HubApi,
        configuration: H3Configuration
    ) throws -> H3TextEncoder {
        let prefix: String
        if globals["model.embed_tokens.weight"] != nil {
            prefix = "model."
        } else if globals["model.language_model.embed_tokens.weight"] != nil {
            prefix = "model.language_model."
        } else {
            throw H3LoaderError.missingTensor(
                "model.embed_tokens.weight or "
                + "model.language_model.embed_tokens.weight")
        }
        let embeddingName = prefix + "embed_tokens.weight"
        guard let embedTokens = globals[embeddingName] else {
            throw H3LoaderError.missingTensor(embeddingName)
        }
        return H3TextEncoder(
            embedTokens: embedTokens,
            prefix: prefix,
            hub: hub, configuration: configuration,
            config: configuration.textEncoder)
    }

    /// The vision half: the 27-block tower over an image or a sampled video.
    ///
    /// The tower is declared empty and filled by path from the same read of the
    /// checkpoint the language half uses. Both directions are checked, and that is
    /// deliberate: the declaration sizes itself from
    /// ``H3VisionEncoderConfiguration``, and where a projection's width is not
    /// spelled out there it is derived — the mergers' `linear_fc1` is the one this
    /// cannot confirm without the checkpoint to hand. A wrong guess would
    /// otherwise fill nothing and leave the placeholder in place, and the tower
    /// would produce a plausible image from a wrongly-shaped matmul with nothing
    /// to point at. Checked, it names the path and both shapes and stops.
    static func loadVisionEncoder(
        globals: [String: MLXArray]
    ) throws -> H3VisionEncoder {
        let prefix = globals.keys.contains(where: { $0.hasPrefix("model.visual.") })
            ? "model.visual."
            : "visual."
        var parameters: [String: MLXArray] = [:]
        for (name, array) in globals where name.hasPrefix(prefix) {
            parameters[String(name.dropFirst(prefix.count))] = array
        }

        let model = H3VisionEncoder()
        try model.update(
            parameters: ModuleParameters.unflattened(parameters),
            verify: [.none])
        return model
    }

    /// Loads the tensors whose names satisfy `matching`.
    ///
    /// The checkpoint's index says which file holds each one, so only the files
    /// that actually carry such a tensor are opened. Opening one costs its header
    /// and nothing more: MLX reads each tensor's bytes from its own offset when
    /// something evaluates it, so a file held here occupies memory only for the
    /// tensors that are actually used. What lives on afterwards is the handles,
    /// not the weights.
    static func loadWeights(
        from url: URL,
        matching: (String) -> Bool
    ) throws -> [String: MLXArray] {
        let map = try weightMap(for: url)
        if map.isEmpty {
            let weights = try loadWeights(from: url).filter { matching($0.key) }
            Memory.clearCache()
            guard !weights.isEmpty else { throw H3LoaderError.emptyWeights(url) }
            return weights
        }

        let directory = url.deletingLastPathComponent()
        let names = map.keys.filter(matching)

        var kept = [String: MLXArray]()
        for file in Set(names.map { map[$0] ?? url.lastPathComponent }) {
            let tensors = try MLX.loadArrays(url: directory.appending(component: file))
            for name in names where (map[name] ?? url.lastPathComponent) == file {
                kept[name] = tensors[name]
            }
            Memory.clearCache()
        }
        guard !kept.isEmpty else { throw H3LoaderError.emptyWeights(url) }
        return kept
    }

    /// Tensor name -> the file that holds it, from the checkpoint's own index.
    ///
    /// `.index.json` names every tensor and the shard it lives in, so nothing
    /// here opens a shard to find out what is inside it. A single-file
    /// checkpoint has no index: every tensor answers with that file.
    static func weightMap(for url: URL) throws -> [String: String] {
        guard url.lastPathComponent.hasSuffix(".index.json") else {
            return [:]   // one file holds everything; see `file(holding:in:)`
        }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let map = object["weight_map"] as? [String: String]
        else {
            throw H3LoaderError.invalidIndex(url)
        }
        return map
    }

    /// Resolves a weight file to the shards it names, or to itself when it is a
    /// single file. Internal rather than private because the layer loaders need
    /// the same resolution and a second copy of it would be a second thing to
    /// keep correct.
    static func shardURLs(for url: URL) throws -> [URL] {
        guard url.lastPathComponent.hasSuffix(".index.json") else {
            return [url]
        }

        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weightMap = object["weight_map"] as? [String: String]
        else {
            throw H3LoaderError.invalidIndex(url)
        }

        let directory = url.deletingLastPathComponent()
        let shards = Array(Set(weightMap.values))
            .sorted()
            .map { directory.appendingPathComponent($0) }
        guard !shards.isEmpty,
              shards.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) })
        else {
            let missing = shards.first(where: { !FileManager.default.fileExists(atPath: $0.path) })
                ?? directory
            throw H3LoaderError.missingShard(missing)
        }
        return shards
    }

}
