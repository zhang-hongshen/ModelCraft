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

    private let lock = NSLock()
    private let cacheDirectory: URL
    private let memoryBudget: Int
    private var entries: [String: Entry] = [:]
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
        insert(snapshot, for: key, metadata: diskMetadata, cost: cost)

        do {
            try persist(snapshot, for: key, metadata: diskMetadata)
        } catch {
            // The in-memory snapshot remains available when disk persistence fails.
        }
    }

    func cachedCopy(for key: String) -> [any KVCache]? {
        if let memoryCopy = copyFromMemory(for: key) {
            return memoryCopy
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

            return snapshot.map { $0.copy() }
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
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

    private func copyFromMemory(for key: String) -> [any KVCache]? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = entries[key] else {
            return nil
        }

        entry.lastAccess = nextClockValue()
        return entry.cache.map { $0.copy() }
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
