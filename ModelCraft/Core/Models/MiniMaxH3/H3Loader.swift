//
//  H3Loader.swift
//  ModelCraft
//
//  Created by Hongshen on 27/8/26.
//

import Foundation
import Hub
import MLX


public enum H3LoaderError: Error, LocalizedError {
    case missingFileKey(H3FileKey)
    case fileNotFound(URL)
    case invalidIndex(URL)
    case missingShard(URL)
    case duplicateTensor(String)
    case emptyWeights(URL)

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
        case .duplicateTensor(let name):
            return "Tensor appears in more than one SafeTensors shard: \(name)"
        case .emptyWeights(let url):
            return "No weights were loaded from \(url.path)"
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

    /// Loads a configured SafeTensors file or all shards referenced by its
    /// `.index.json` file.
    static func loadWeights(
        hub: HubApi,
        configuration: H3Configuration,
        key: H3FileKey
    ) throws -> [String: MLXArray] {
        try loadWeights(from: try resolve(hub: hub, configuration: configuration, key: key))
    }

    /// Decodes a JSON configuration selected by an ``H3FileKey`` in H3Configuration.
    /// Concrete modules may use this when a future checkpoint exposes a
    /// variant-specific architecture field; the preset remains the source of
    /// truth for which file is downloaded.
    static func loadConfiguration<T: Decodable>(
        hub: HubApi,
        configuration: H3Configuration,
        key: H3FileKey,
        type: T.Type
    ) throws -> T {
        let url = try resolve(hub: hub, configuration: configuration, key: key)
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    /// Loads a single SafeTensors file or all shards referenced by its
    /// `.index.json` file. This overload is kept for the low-level weight
    /// containers that already received a resolved URL.
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

    static func loadAudioVAEEncoder(hub: HubApi, configuration: H3Configuration) throws -> H3AudioVAEEncoder {
        let audioVAEWeights = try loadWeights(
            hub: hub,
            configuration: configuration,
            key: .audioVAEWeights)
        return try H3AudioVAEEncoder(weights: audioVAEWeights)
    }

    /// Loads and constructs the H3 Omni Transformer from its configured
    /// SafeTensors file or shard index. The indexed weight accessor remains an
    /// implementation detail of the loader.
    static func loadOmniTransformer(
        hub: HubApi,
        configuration: H3Configuration,
        computeDType: DType = .bfloat16,
        backend: any H3AttentionBackend = SDPABackend()
    ) throws -> H3OmniTransformer {
        try H3OmniTransformer(
            weights: try H3BaseWeights(
                hub: hub,
                configuration: configuration,
                key: .transformerWeights),
            computeDType: computeDType,
            backend: backend)
    }

    private static func shardURLs(for url: URL) throws -> [URL] {
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


/// SafeTensors-backed weight access for the H3 Base transformer.
///
/// The public Hugging Face component weights are sharded (`model-00001-of-00013` plus
/// `model.safetensors.index.json`), while several local MLX conversions are a
/// single SafeTensors file. Keeping the shard resolution here means the
/// transformer never needs to know which distribution the user downloaded.
final class H3BaseWeights {
    let url: URL
    let config: H3Configuration

    private let sources: [URL]
    private let lock = NSLock()
    private var cache: [String: MLXArray] = [:]
    private var all: [String: MLXArray]?

    enum Error: Swift.Error, CustomStringConvertible {
        case invalid(String)
        case missing(String)

        var description: String {
            switch self {
            case .invalid(let message): "invalid MiniMax H3 weights: \(message)"
            case .missing(let name): "weights have no tensor named \(name)"
            }
        }
    }

    init(url: URL, strict: Bool = true) throws {
        self.url = url
        self.sources = try Self.resolveSources(for: url)

        var infos: [String: H3Loader.SafeTensors.TensorInfo] = [:]
        for source in sources {
            let archive = try H3Loader.SafeTensors.Archive(url: source)
            for (name, info) in archive.tensors {
                guard infos[name] == nil else {
                    throw Error.invalid("tensor \(name) appears in more than one shard")
                }
                infos[name] = info
            }
        }

        self.config = try Self.deriveConfig(from: infos, strict: strict)
    }

    convenience init(
        hub: HubApi,
        configuration: H3Configuration,
        key: H3FileKey,
        strict: Bool = true
    ) throws {
        try self.init(
            url: H3Loader.resolve(
                hub: hub,
                configuration: configuration,
                key: key),
            strict: strict)
    }

    private static func resolveSources(for url: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.invalid("file not found at \(url.path)")
        }
        guard url.lastPathComponent.hasSuffix(".index.json") else { return [url] }

        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weightMap = object["weight_map"] as? [String: String]
        else {
            throw Error.invalid("\(url.lastPathComponent) has no valid weight_map")
        }

        let directory = url.deletingLastPathComponent()
        let shards = Array(Set(weightMap.values)).sorted().map { directory.appendingPathComponent($0) }
        guard !shards.isEmpty else { throw Error.invalid("the shard index is empty") }
        let missing = shards.filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard missing.isEmpty else {
            throw Error.invalid("missing shard(s): " + missing.map(\.lastPathComponent).joined(separator: ", "))
        }
        return shards
    }

    private static func deriveConfig(
        from infos: [String: H3Loader.SafeTensors.TensorInfo],
        strict: Bool
    ) throws -> H3Configuration {
        guard infos["video_patch_proj.weight"] != nil,
              infos["audio_patch_proj.weight"] != nil
        else {
            throw Error.invalid("video_patch_proj.weight and audio_patch_proj.weight are required")
        }

        func shape(_ name: String) -> [Int]? { infos[name]?.shape }
        func countBlocks(prefix: String) throws -> Int {
            let indexes = Set(infos.keys.compactMap { key -> Int? in
                guard key.hasPrefix(prefix) else { return nil }
                let rest = key.dropFirst(prefix.count)
                guard let dot = rest.firstIndex(of: ".") else { return nil }
                return Int(rest[rest.startIndex ..< dot])
            })
            guard let highest = indexes.max() else {
                throw Error.invalid("no tensors found under \(prefix)")
            }
            guard indexes.count == highest + 1 else {
                throw Error.invalid("\(prefix) indexes are not contiguous")
            }
            return highest + 1
        }

        var config = H3Configuration(id: "derived")
        config.numLayers = try countBlocks(prefix: "blocks.")
        config.tokenRefinerLayers = try countBlocks(prefix: "token_refiner.blocks.")
        if let s = shape("video_patch_proj.weight"), !s.isEmpty { config.hiddenSize = s[0] }
        if let s = shape("final_layer.video_out.weight"), !s.isEmpty {
            config.videoLatentDim = s[0] / config.patchSize.reduce(1, *)
        }
        if let s = shape("final_layer.audio_out.weight"), !s.isEmpty { config.audioLatentDim = s[0] }
        if let s = shape("blocks.0.attn.q_norm.weight"), !s.isEmpty { config.headDim = s[0] }
        if let s = shape("blocks.0.attn.qkv_proj.weight"), config.headDim > 0, !s.isEmpty {
            config.numHeads = s[0] / (3 * config.headDim)
        }
        if let s = shape("blocks.0.mlp.fc1.weight"), !s.isEmpty { config.ffnHidden = s[0] / 2 }
        if let s = shape("condition_proj.weight"), s.count > 1 { config.textDim = s[1] }
        if let s = shape("rope.inv_freq"), !s.isEmpty { config.ropeInvFreqLen = s[0] }
        if let s = shape("time_embedder.proj_in.weight"), s.count > 1 {
            config.timeEmbedHidden = s[0]
            config.timestepInputDim = s[1]
        }
        if let s = shape("time_embedder.proj_out.weight"), !s.isEmpty { config.timeEmbedDim = s[0] }

        if strict {
            let expected = H3Configuration(id: "expected", files: [:])
            let checks: [(String, Int, Int)] = [
                ("numLayers", config.numLayers, expected.numLayers),
                ("tokenRefinerLayers", config.tokenRefinerLayers, expected.tokenRefinerLayers),
                ("hiddenSize", config.hiddenSize, expected.hiddenSize),
                ("numHeads", config.numHeads, expected.numHeads),
                ("headDim", config.headDim, expected.headDim),
                ("ffnHidden", config.ffnHidden, expected.ffnHidden),
                ("videoLatentDim", config.videoLatentDim, expected.videoLatentDim),
                ("audioLatentDim", config.audioLatentDim, expected.audioLatentDim),
                ("textDim", config.textDim, expected.textDim),
                ("ropeInvFreqLen", config.ropeInvFreqLen, expected.ropeInvFreqLen),
                ("timeEmbedDim", config.timeEmbedDim, expected.timeEmbedDim),
            ]
            let mismatches = checks.filter { $0.1 != $0.2 }
            if !mismatches.isEmpty {
                throw Error.invalid(mismatches.map { "\($0.0)=\($0.1), expected \($0.2)" }.joined(separator: "; "))
            }
        }
        return config
    }

    func loadAll() throws {
        lock.lock()
        defer { lock.unlock() }
        guard all == nil else { return }

        var loaded: [String: MLXArray] = [:]
        for source in sources {
            for (name, value) in try MLX.loadArrays(url: source) {
                guard loaded[name] == nil else { throw Error.invalid("duplicate tensor \(name)") }
                loaded[name] = value
            }
        }
        guard !loaded.isEmpty else { throw Error.invalid("no tensors were loaded") }
        all = loaded
    }

    func tensor(_ name: String) throws -> MLXArray {
        lock.lock()
        defer { lock.unlock() }
        if let value = cache[name] { return value }
        if all == nil {
            var loaded: [String: MLXArray] = [:]
            for source in sources {
                for (key, value) in try MLX.loadArrays(url: source) {
                    guard loaded[key] == nil else { throw Error.invalid("duplicate tensor \(key)") }
                    loaded[key] = value
                }
            }
            all = loaded
        }
        guard let value = all?[name] else { throw Error.missing(name) }
        cache[name] = value
        return value
    }

    func describe(_ name: String) throws -> H3Loader.SafeTensors.TensorInfo {
        for source in sources {
            let archive = try H3Loader.SafeTensors.Archive(url: source)
            if let info = archive.tensors[name] { return info }
        }
        throw Error.missing(name)
    }

    func has(_ name: String) -> Bool { (try? describe(name)) != nil }

    subscript(name: String) -> MLXArray? { try? tensor(name) }
}
