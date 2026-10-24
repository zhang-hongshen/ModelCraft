//
//  DeepSeekFlashExpertCache.swift
//  ModelCraft
//
//  Created by Hongshen on 24/10/26.
//

import Foundation
import MLX

/// Where one MoE block's routed experts live on disk.
struct DeepSeekFlashExpertSource {
    let cache: DeepSeekFlashExpertCache
    let url: URL
    /// The tensor name prefix of the block's experts, such as `layers.5.ffn.experts.`.
    let prefix: String
}

/// Routed expert weights read from the checkpoint when a step routes to them, kept while they
/// fit in `budget` bytes and evicted least recently used first.
final class DeepSeekFlashExpertCache {
    /// The tensors of one expert, in the order `DeepSeekFlashSwitchGLU(stacking:)` expects.
    static let tensorNames = [
        "w1.weight", "w1.scale", "w2.weight", "w2.scale", "w3.weight", "w3.scale",
    ]

    private struct Entry {
        let arrays: [MLXArray]
        let byteCount: Int
        var lastUse: Int
    }

    var budget = 0
    private var entries: [String: Entry] = [:]
    private var byteCount = 0
    private var useCount = 0
    /// Separate CPU streams, so expert reads run alongside each other and alongside GPU work.
    private let streams = (0 ..< 4).map { _ in Stream(.cpu) }

    /// Returns the weights of `expertIDs`, starting reads for those not held yet. The returned
    /// arrays may still be loading; evaluating them waits for their reads.
    func experts(
        _ expertIDs: [Int],
        from source: DeepSeekFlashExpertSource
    ) throws -> [[MLXArray]] {
        useCount += 1
        let keys = expertIDs.map { source.prefix + String($0) }
        let missingKeys = keys.filter { entries[$0] == nil }
        if !missingKeys.isEmpty {
            var reads = [MLXArray]()
            for (streamIndex, stream) in streams.enumerated() {
                let assignedKeys = stride(
                    from: streamIndex, to: missingKeys.count, by: streams.count
                ).map { missingKeys[$0] }
                guard !assignedKeys.isEmpty else { continue }
                // Loading only parses the header; each tensor is read when it is evaluated.
                let tensors = try MLX.loadArrays(url: source.url, stream: .stream(stream))
                for key in assignedKeys {
                    let arrays = try Self.tensorNames.map { name in
                        guard let array = tensors["\(key).\(name)"] else {
                            throw DeepSeekFlashLoaderError.invalidIndex(source.url)
                        }
                        return array
                    }
                    let size = arrays.reduce(0) { $0 + $1.nbytes }
                    entries[key] = Entry(arrays: arrays, byteCount: size, lastUse: useCount)
                    byteCount += size
                    reads += arrays
                }
            }
            asyncEval(reads)
        }
        for key in keys {
            entries[key]?.lastUse = useCount
        }
        evict()
        return keys.map { entries[$0]!.arrays }
    }

    /// Drops the least recently used experts until the cache fits its budget, keeping the ones
    /// the current step needs.
    private func evict() {
        guard byteCount > budget else { return }
        let candidates = entries
            .filter { $0.value.lastUse < useCount }
            .sorted { $0.value.lastUse < $1.value.lastUse }
        for (key, entry) in candidates {
            guard byteCount > budget else { break }
            entries[key] = nil
            byteCount -= entry.byteCount
        }
    }
}
