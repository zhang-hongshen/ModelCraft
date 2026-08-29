//
//  KVCacheManager.swift
//  ModelCraft
//
//  Created by Hongshen on 16/3/26.
//

import Foundation
import MLX
import MLXLMCommon

final class KVCacheManager {

    static let shared = KVCacheManager()

    /// A value-only cache layout that intentionally ignores the growing KV
    /// sequence axis (axis 2), while retaining all other tensor structure.
    struct CacheLayout: Equatable, Sendable {
        struct Tensor: Equatable, Sendable {
            let dtype: String
            let rank: Int
            let staticShape: [Int?]
        }

        struct Layer: Equatable, Sendable {
            let cacheType: String
            let maxSize: Int?
            let isTrimmable: Bool
            let stableParameters: [String]
            let tensors: [Tensor]
        }

        let layers: [Layer]
    }

    struct CachedSnapshot {
        let cache: [any KVCache]
        let metadata: [String: String]
    }

    private final class Entry {
        let cache: [any KVCache]
        let metadata: [String: String]
        let cost: Int
        var lastAccess: UInt64

        init(cache: [any KVCache], metadata: [String: String], cost: Int, lastAccess: UInt64) {
            self.cache = cache
            self.metadata = metadata
            self.cost = cost
            self.lastAccess = lastAccess
        }
    }

    private struct RegisteredLayout {
        let modelIdentity: ObjectIdentifier
        let layout: CacheLayout
    }

    private let lock = NSLock()
    private let cacheDirectory: URL
    private let memoryBudget: Int
    private var entries: [String: Entry] = [:]
    private var registeredLayouts: [String: RegisteredLayout] = [:]
    private var memoryCost = 0
    private var clock: UInt64 = 0

    init(
        cacheDirectory: URL = URL.cachesDirectory.appendingPathComponent("model-cache"),
        memoryBudget: Int = 128 * 1024 * 1024
    ) {
        self.cacheDirectory = cacheDirectory
        self.memoryBudget = max(0, memoryBudget)
        try? FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true)
    }

    func save(cache: [any KVCache], for key: String, metadata: [String: String] = [:]) {
        let snapshot = cache.map { $0.copy() }
        let state = snapshot.flatMap { $0.state }
        eval(state)
        let cost = state.reduce(0) { $0 + $1.nbytes }

        var diskMetadata = metadata
        diskMetadata["cache_format_version"] = "1"
        diskMetadata["cache_state_signature"] = Self.stateSignature(for: snapshot)
        diskMetadata["cache_layout_signature"] = Self.layoutSignature(for: snapshot)
        insert(snapshot, for: key, metadata: diskMetadata, cost: cost)

        do {
            try persist(snapshot, for: key, metadata: diskMetadata)
        } catch {
            // The in-memory snapshot remains available when disk persistence fails.
        }
    }

    func cachedCopy(for key: String) -> [any KVCache]? {
        cachedSnapshot(for: key)?.cache
    }

    func cachedSnapshot(for key: String) -> CachedSnapshot? {
        if let memorySnapshot = snapshotFromMemory(for: key) {
            return memorySnapshot
        }

        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let (loadedCache, metadata) = try loadPromptCache(url: url)
            guard metadata["cache_format_version"] == "1" else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }

            let snapshot = loadedCache.map { $0.copy() }
            let state = snapshot.flatMap { $0.state }
            eval(state)
            let cost = state.reduce(0) { $0 + $1.nbytes }
            insert(snapshot, for: key, metadata: metadata, cost: cost)

            return CachedSnapshot(
                cache: snapshot.map { $0.copy() },
                metadata: metadata)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    static func stateSignature(for cache: [any KVCache]) -> String {
        cache.map { cache in
            let state = cache.state
            let tensors = state.map { tensor in
                let shape = tensor.shape.map(String.init).joined(separator: ",")
                return "\(tensor.dtype)[\(shape)]"
            }.joined(separator: ";")
            return "\(state.count):\(tensors)"
        }.joined(separator: "|")
    }

    static func layout(for cache: [any KVCache]) -> CacheLayout {
        CacheLayout(layers: cache.map { cache in
            let stableParameters: [String]
            if let quantized = cache as? any QuantizedKVCacheProtocol {
                stableParameters = [
                    "quantization.groupSize=\(quantized.groupSize)",
                    "quantization.bits=\(quantized.bits)",
                    "quantization.mode=\(quantized.mode)",
                ]
            } else {
                stableParameters = []
            }
            return CacheLayout.Layer(
                cacheType: String(reflecting: type(of: cache)),
                maxSize: cache.maxSize,
                isTrimmable: cache.isTrimmable,
                stableParameters: stableParameters,
                tensors: cache.state.map { tensor in
                    CacheLayout.Tensor(
                        dtype: String(describing: tensor.dtype),
                        rank: tensor.shape.count,
                        staticShape: tensor.shape.enumerated().map {
                            $0.offset == 2 ? nil : $0.element
                        })
                })
        })
    }

    static func layoutSignature(for cache: [any KVCache]) -> String {
        layout(for: cache).layers.map { layer in
            let tensors = layer.tensors.map { tensor in
                let shape = tensor.staticShape.map { $0.map(String.init) ?? "*" }
                    .joined(separator: ",")
                return "\(tensor.dtype):\(tensor.rank)[\(shape)]"
            }.joined(separator: ";")
            return "\(layer.cacheType)|\(layer.maxSize.map(String.init) ?? "nil")|"
                + "\(layer.isTrimmable)|\(layer.stableParameters.joined(separator: ","))|\(tensors)"
        }.joined(separator: "||")
    }

    static func layoutsCompatible(cached: CacheLayout, expected: CacheLayout) -> Bool {
        cached == expected
    }

    func registeredLayout(for modelID: String, modelIdentity: ObjectIdentifier) -> CacheLayout? {
        lock.lock()
        defer { lock.unlock() }
        guard let registered = registeredLayouts[modelID],
              registered.modelIdentity == modelIdentity
        else {
            return nil
        }
        return registered.layout
    }

    func registerLayout(
        _ layout: CacheLayout,
        for modelID: String,
        modelIdentity: ObjectIdentifier
    ) {
        lock.lock()
        registeredLayouts[modelID] = RegisteredLayout(
            modelIdentity: modelIdentity,
            layout: layout)
        lock.unlock()
    }

    func load(for key: String, into cache: inout [any KVCache]) -> Bool {
        guard let loaded = cachedCopy(for: key), !loaded.isEmpty else {
            return false
        }

        cache = loaded
        return true
    }

    func clear(for key: String) {
        lock.lock()
        removeEntry(for: key)
        lock.unlock()

        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    func clearAll() {
        lock.lock()
        entries.removeAll()
        memoryCost = 0
        clock = 0
        lock.unlock()

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for url in contents where isManagedCacheFile(url) {
            guard let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  resourceValues.isDirectory != true
            else {
                continue
            }

            try? FileManager.default.removeItem(at: url)
        }
    }

    func removeMemoryCopy(for key: String) {
        lock.lock()
        removeEntry(for: key)
        lock.unlock()
    }

    func fileURL(for key: String) -> URL {
        cacheDirectory
            .appendingPathComponent(key.sha256String)
            .appendingPathExtension("safetensors")
    }

    private func snapshotFromMemory(for key: String) -> CachedSnapshot? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = entries[key] else {
            return nil
        }

        entry.lastAccess = nextClockValue()
        return CachedSnapshot(
            cache: entry.cache.map { $0.copy() },
            metadata: entry.metadata)
    }

    private func persist(
        _ cache: [any KVCache],
        for key: String,
        metadata: [String: String]
    ) throws {
        let fileManager = FileManager.default
        let destinationURL = fileURL(for: key)
        let temporaryURL = cacheDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("safetensors")

        do {
            try fileManager.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            try savePromptCache(url: temporaryURL, cache: cache, metadata: metadata)

            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func insert(
        _ cache: [any KVCache],
        for key: String,
        metadata: [String: String],
        cost: Int
    ) {
        lock.lock()
        defer { lock.unlock() }

        removeEntry(for: key)
        entries[key] = Entry(
            cache: cache,
            metadata: metadata,
            cost: cost,
            lastAccess: nextClockValue()
        )
        memoryCost += cost

        while memoryCost > memoryBudget,
              let oldestKey = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            removeEntry(for: oldestKey)
        }
    }

    private func removeEntry(for key: String) {
        guard let entry = entries.removeValue(forKey: key) else {
            return
        }

        memoryCost -= entry.cost
    }

    private func nextClockValue() -> UInt64 {
        clock &+= 1
        return clock
    }

    private func isManagedCacheFile(_ url: URL) -> Bool {
        let digest = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension == "safetensors", digest.count == 64 else {
            return false
        }

        return digest.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }
}
