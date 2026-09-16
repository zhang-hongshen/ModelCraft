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
    case invalidIndex(URL)
    case missingShard(URL)
    case missingLayer(Int)
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
        case .invalidIndex(let url):
            return "Invalid SafeTensors shard index: \(url.path)"
        case .missingShard(let url):
            return "SafeTensors shard is missing: \(url.path)"
        case .missingLayer(let index):
            return "No SafeTensors shard holds layer \(index)"
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
    /// This is the bottom of the weight stack: the only function in the H3 family
    /// that reads tensor bytes. Everything above it — the encoder's embedding
    /// table and vision tower, the Omni Transformer, both VAE directions, and the
    /// three layer stacks through the `load…Layer` readers below — is handed what
    /// it needs from here and never opens the checkpoint itself.
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
    /// `build` is dropped as soon as it returns, and a layer that keeps only the
    /// arrays it read gives the shard back with it.
    private static func readLayer<Layer>(
        _ index: Int,
        of url: URL,
        count: Int,
        index indexOfTensor: (String) -> Int?,
        build: (Int, [String: MLXArray]) throws -> Layer
    ) throws -> Layer {
        let tensors = try loadWeights(
            from: try shardURL(holding: index, of: url, count: count, index: indexOfTensor))
        return try build(index, tensors)
    }

    /// Loads one layer of the text encoder's language stack.
    ///
    /// The caller holds whichever layers it has room for; this reads only the one
    /// asked for. See ``H3TextEncoder/encode(embeds:computeDType:positionIds:visualSpans:deepstack:)``.
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
        try readLayer(
            index, of: url, count: config.numLayers,
            index: { name in
                for layerPrefix in ["model.language_model.layers.", "model.layers."] {
                    guard name.hasPrefix(layerPrefix) else { continue }
                    let rest = name.dropFirst(layerPrefix.count)
                    guard let dot = rest.firstIndex(of: ".") else { return nil }
                    return Int(rest[rest.startIndex ..< dot])
                }
                return nil
            }
        ) { index, tensors in
            let root = "\(prefix)layers.\(index)."
            var parameters: [String: MLXArray] = [:]
            for (name, array) in tensors where name.hasPrefix(root) {
                parameters[String(name.dropFirst(root.count))] = array
            }
            let layer = H3TextEncoderLayer(config: config)
            try layer.update(
                parameters: ModuleParameters.unflattened(parameters),
                verify: [.allModelKeysSet, .shapeMismatch])
            return layer
        }
    }

    /// Loads one layer of the Omni Transformer's stack.
    ///
    /// Declared and then filled from the slice of the shard whose names start
    /// `blocks.<index>.`, so there is one construction path and a tensor cannot be
    /// wired to the wrong matrix. Every declared parameter has to arrive and every
    /// shape has to agree: a mis-wired layer would not fail to load, it would
    /// denoise to a plausible-looking wrong video, and this is the only place that
    /// can tell the difference.
    static func loadTransformerLayer(
        index: Int,
        url: URL,
        config: H3Configuration
    ) throws -> H3OmniTransformerLayer {
        try readLayer(
            index, of: url, count: config.numLayers,
            index: { name in
                let prefix = "transformer_blocks."
                guard name.hasPrefix(prefix) else { return nil }
                let rest = name.dropFirst(prefix.count)
                guard let dot = rest.firstIndex(of: ".") else { return nil }
                return Int(rest[rest.startIndex ..< dot])
            }
        ) { index, tensors in
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
            let layer = H3OmniTransformerLayer(config: config)
            try layer.update(
                parameters: ModuleParameters.unflattened(parameters),
                verify: [.allModelKeysSet, .shapeMismatch])
            return layer
        }
    }

    /// Loads one block of the video VAE's decoder stack.
    ///
    /// Declared and then filled from the slice of the file whose names start
    /// `decoder.transformer_blocks.<index>.`, so there is one construction path
    /// and a tensor cannot be wired to the wrong matrix. Both directions are
    /// checked: a mis-wired block would not fail to load, it would produce a
    /// plausible-looking wrong frame.
    static func loadDecoderLayer(
        index: Int,
        url: URL,
        config: H3VideoVAEConfiguration
    ) throws -> VaeTransformerBlock {
        try readLayer(
            index, of: url, count: config.decoderLayers,
            index: { name in
                let prefix = "decoder.transformer_blocks."
                guard name.hasPrefix(prefix) else { return nil }
                let rest = name.dropFirst(prefix.count)
                guard let dot = rest.firstIndex(of: ".") else { return nil }
                return Int(rest[rest.startIndex ..< dot])
            }
        ) { index, tensors in
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
            let block = VaeTransformerBlock(config: config)
            try block.update(
                parameters: ModuleParameters.unflattened(parameters),
                verify: [.allModelKeysSet, .shapeMismatch])
            return block
        }
    }

    /// Loads the Omni Transformer: everything outside its layer stack.
    ///
    /// 1.72 GB of refiner, time embedder, final layer and projections, held once
    /// per render rather than read once per step. The 50 layers are not loaded
    /// here — they are 64.56 GB and are read by
    /// ``H3OmniTransformer/runStack(_:)`` as the step reaches each of them, unless
    /// the machine's profile keeps a whole component resident.
    ///
    /// The model is declared empty and filled by name; the names need no
    /// translating, since the checkpoint already spells them the way the
    /// declaration reads. Both directions are checked: a parameter the
    /// declaration has and the checkpoint does not is named, and so is one whose
    /// shape disagrees. See ``loadTransformerLayer(index:url:config:)``.
    static func loadOmniTransformer(
        hub: HubApi,
        configuration: H3Configuration,
        computeDType: DType = .bfloat16,
        report: (String) -> Void = { _ in }
    ) throws -> H3OmniTransformer {
        let url = try resolve(hub: hub, configuration: configuration, key: .transformerWeights)
        let globals = try outsideStack(
            at: url,
            belongs: { name in
                let prefix = "transformer_blocks."
                guard name.hasPrefix(prefix) else { return true }
                let rest = name.dropFirst(prefix.count)
                guard let dot = rest.firstIndex(of: ".") else { return true }
                return Int(rest[rest.startIndex ..< dot]) == nil
            },
            report: report)

        let model = H3OmniTransformer(
            config: configuration,
            hub: hub,
            configuration: configuration,
            // A denoise run walks all 50 layers once per step, so reading them
            // whole pays off only where the stack fits — and no tier this app has
            // a preset for reaches that. See ``H3RuntimeProfile``.
            releasesLayersAfterUse: !configuration.runtimeProfile.loadsComponentsEagerly,
            computeDType: computeDType)
        // The refiner's blocks carry the export's list indices too, so the whole
        // map is folded, not just each layer's slice.
        try model.update(
            parameters: ModuleParameters.unflattened(
                globals.reduce(into: [String: MLXArray]()) {
                    let key = $1.key
                        .replacingOccurrences(of: ".attn.to_out.0.", with: ".attn.toOut.")
                        .replacingOccurrences(of: ".ff.net.0.proj.", with: ".ff.w1.")
                        .replacingOccurrences(of: ".ff.net.2.", with: ".ff.w2.")
                        .replacingOccurrences(
                            of: ".downsamplers.0.", with: ".downsamplers.")
                    $0[key] = $1.value
                }),
            verify: [.allModelKeysSet, .shapeMismatch])
        return model
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
        let configuration = try configurationWithVideoVAE(
            hub: hub, configuration: configuration)
        let tensors = try loadWeights(from: try resolve(
            hub: hub, configuration: configuration, key: .videoVAEWeights))
        let vae = H3VisualVAE(hub: hub, configuration: configuration)

        var local: [String: MLXArray] = [:]
        for (name, array) in tensors {
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
        try vae.update(
            parameters: ModuleParameters.unflattened(local),
            verify: [.allModelKeysSet, .shapeMismatch])
        return vae
    }

    /// The configuration with the video VAE's dimensions read out of its own
    /// `config.json` and stored in it.
    ///
    /// The components then hold one value that carries both where their tensors
    /// are and how wide they are, and resolve the file themselves when a read
    /// needs it. A copy: ``H3Configuration`` is a value, so the parse stays with
    /// whoever asked for this component.
    static func configurationWithVideoVAE(
        hub: HubApi,
        configuration: H3Configuration
    ) throws -> H3Configuration {
        var configuration = configuration
        configuration.videoVAE = try videoVAEConfiguration(at: try resolve(
            hub: hub, configuration: configuration, key: .videoVAEConfig))
        return configuration
    }

    /// The video VAE's dimensions, read from the checkpoint's own `config.json`.
    ///
    /// Every one of them is stated there — widths, strides, layer counts, the
    /// latent normalization — so nothing about this VAE's shape is written down in
    /// code twice. A re-export with different widths loads without an edit.
    static func videoVAEConfiguration(at url: URL) throws -> H3VideoVAEConfiguration {
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
        let configuration = try configurationWithAudioVAE(
            hub: hub, configuration: configuration)
        let tensors = try loadWeights(from: try resolve(
            hub: hub, configuration: configuration, key: .audioVAEWeights))
        let vae = H3AudioVAE(configuration: configuration)

        var local: [String: MLXArray] = [:]
        for (name, array) in tensors {
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
            verify: [.allModelKeysSet, .shapeMismatch])
        return vae
    }

    /// The configuration with the audio VAE's dimensions read out of its own
    /// `config.json` and stored in it.
    ///
    /// Same arrangement as ``configurationWithVideoVAE(hub:configuration:)``, and
    /// for the same reason: `latents_mean` and `latents_std` are in this file and
    /// not among the weights, so nothing can denormalize without having read it.
    static func configurationWithAudioVAE(
        hub: HubApi,
        configuration: H3Configuration
    ) throws -> H3Configuration {
        var configuration = configuration
        configuration.audioVAE = try audioVAEConfiguration(at: try resolve(
            hub: hub, configuration: configuration, key: .audioVAEConfig))
        return configuration
    }

    /// The audio VAE's dimensions, read from the checkpoint's own `config.json`.
    ///
    /// Every width, rate, kernel size and layer count the audio VAE has is stated
    /// there, along with its sampling rate and the latent normalization, so none
    /// of them is written down in code twice.
    static func audioVAEConfiguration(at url: URL) throws -> H3AudioVAEConfiguration {
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
        let vocabulary = try resolve(
            hub: hub, configuration: configuration, key: .tokenizerVocabulary)
        return try H3Tokenizer(directory: vocabulary.deletingLastPathComponent())
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
        var globals = try outsideStack(
            at: try resolve(
                hub: hub, configuration: configuration, key: .textEncoderWeights),
            belongs: { name in
                for prefix in ["model.language_model.layers.", "model.layers."] {
                    guard name.hasPrefix(prefix) else { continue }
                    let rest = name.dropFirst(prefix.count)
                    guard let dot = rest.firstIndex(of: ".") else { return true }
                    return Int(rest[rest.startIndex ..< dot]) == nil
                }
                return true
            })
        globals["lm_head.weight"] = nil
        return globals
    }

    /// The language half: the embedding table and the layer stack's tensor names.
    ///
    /// The language layers themselves are not here — they are 62.41 GB and
    /// ``H3TextEncoder/encode(embeds:computeDType:positionIds:visualSpans:deepstack:)``
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

        let tower = H3VisionEncoder()
        try tower.update(
            parameters: ModuleParameters.unflattened(parameters),
            verify: [.allModelKeysSet, .shapeMismatch])
        return tower
    }

    /// Every tensor of a component that is not part of a layer stack.
    ///
    /// The checkpoint's index says which file holds each one, so only the files
    /// that actually carry such a tensor are opened. Opening one costs its header
    /// and nothing more: MLX reads each tensor's bytes from its own offset when
    /// something evaluates it, so a file held here occupies memory only for the
    /// tensors that are actually used. What lives on afterwards is the handles,
    /// not the weights.
    static func outsideStack(
        at url: URL,
        belongs: (String) -> Bool,
        report: (String) -> Void = { _ in }
    ) throws -> [String: MLXArray] {
        let map = try weightMap(for: url)
        let directory = url.deletingLastPathComponent()
        let names = map.isEmpty
            ? try tensorNames(in: shardURLs(for: url)).filter(belongs)
            : map.keys.filter(belongs)

        var kept = [String: MLXArray]()
        for file in Set(names.map { map[$0] ?? url.lastPathComponent }) {
            report("reading \(file)")
            let tensors = try MLX.loadArrays(url: directory.appending(component: file))
            for name in names where (map[name] ?? url.lastPathComponent) == file {
                kept[name] = tensors[name]
            }
            Memory.clearCache()
        }
        guard !kept.isEmpty else { throw H3LoaderError.emptyWeights(url) }
        return kept
    }

    /// Every tensor name the checkpoint's shards declare. Headers only.
    private static func tensorNames(in shards: [URL]) throws -> [String] {
        try shards.flatMap { try SafeTensors.Archive(url: $0).tensors.keys }
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

    /// Header-only SafeTensors metadata used to validate and build the H3 Base
    /// components. Actual tensor bytes are loaded by `loadWeights(from:)`.
    enum SafeTensors {
        struct TensorInfo: Sendable {
            let dtype: String
            let shape: [Int]
            let begin: Int
            let end: Int
        }

        enum Error: Swift.Error, CustomStringConvertible {
            case tooSmall
            case badHeader(String)
            case unsupportedDType(String)

            var description: String {
                switch self {
                case .tooSmall:
                    "file too small to be SafeTensors"
                case .badHeader(let message):
                    "invalid SafeTensors header: \(message)"
                case .unsupportedDType(let dtype):
                    "unsupported SafeTensors dtype: \(dtype)"
                }
            }
        }

        struct Archive {
            let tensors: [String: TensorInfo]
            let metadata: [String: String]

            init(url: URL) throws {
                let fileHandle = try FileHandle(forReadingFrom: url)
                defer { try? fileHandle.close() }

                let fileSize = try fileHandle.seekToEnd()
                try fileHandle.seek(toOffset: 0)
                guard let lengthData = try fileHandle.read(upToCount: 8),
                      lengthData.count == 8
                else {
                    throw Error.tooSmall
                }

                let headerLength = lengthData.withUnsafeBytes {
                    $0.loadUnaligned(as: UInt64.self).littleEndian
                }
                let maximumHeaderBytes: UInt64 = 64 * 1024 * 1024
                guard headerLength > 0, headerLength <= maximumHeaderBytes else {
                    throw Error.badHeader("implausible length \(headerLength)")
                }
                guard headerLength <= fileSize - 8 else {
                    throw Error.badHeader(
                        "header length \(headerLength) exceeds file size \(fileSize)")
                }
                guard let headerData = try fileHandle.read(upToCount: Int(headerLength)),
                      headerData.count == Int(headerLength)
                else {
                    throw Error.tooSmall
                }
                guard let object = try JSONSerialization.jsonObject(with: headerData)
                        as? [String: Any]
                else {
                    throw Error.badHeader("not a JSON object")
                }

                let payloadBytes = Int(fileSize - 8 - headerLength)
                let byteWidth: [String: Int] = [
                    "BOOL": 1, "I8": 1, "U8": 1,
                    "I16": 2, "U16": 2, "F16": 2, "BF16": 2,
                    "I32": 4, "U32": 4, "F32": 4,
                    "I64": 8, "U64": 8, "F64": 8,
                ]
                var tensorInfos: [String: TensorInfo] = [:]
                var metadata: [String: String] = [:]

                for (name, value) in object {
                    if name == "__metadata__" {
                        metadata = (value as? [String: String]) ?? [:]
                        continue
                    }
                    guard let entry = value as? [String: Any],
                          let dtype = entry["dtype"] as? String,
                          let shape = entry["shape"] as? [Int],
                          let offsets = entry["data_offsets"] as? [Int],
                          offsets.count == 2
                    else {
                        throw Error.badHeader("invalid tensor entry \(name)")
                    }
                    guard shape.allSatisfy({ $0 >= 0 }) else {
                        throw Error.badHeader("negative dimension in \(name)")
                    }
                    var elements = 1
                    for dimension in shape {
                        let product = elements.multipliedReportingOverflow(by: dimension)
                        guard !product.overflow else {
                            throw Error.badHeader("shape overflow in \(name)")
                        }
                        elements = product.partialValue
                    }
                    let begin = offsets[0]
                    let end = offsets[1]
                    guard begin >= 0, end >= begin, end <= payloadBytes else {
                        throw Error.badHeader("offsets outside payload in \(name)")
                    }
                    guard let width = byteWidth[dtype] else {
                        throw Error.unsupportedDType(dtype)
                    }
                    let byteCount = elements.multipliedReportingOverflow(by: width)
                    guard !byteCount.overflow, end - begin == byteCount.partialValue else {
                        throw Error.badHeader("byte count does not match shape in \(name)")
                    }
                    tensorInfos[name] = TensorInfo(
                        dtype: dtype,
                        shape: shape,
                        begin: begin,
                        end: end)
                }

                let ordered = tensorInfos.map {
                    (name: $0.key, begin: $0.value.begin, end: $0.value.end)
                }.sorted { ($0.begin, $0.end, $0.name) < ($1.begin, $1.end, $1.name) }
                for pair in zip(ordered, ordered.dropFirst()) where pair.1.begin < pair.0.end {
                    throw Error.badHeader(
                        "overlapping tensor ranges: \(pair.0.name), \(pair.1.name)")
                }

                self.tensors = tensorInfos
                self.metadata = metadata
            }
        }
    }
}
