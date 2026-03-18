//
//  KVCacheManager.swift
//  ModelCraft
//
//  Created by Hongshen on 16/3/26.
//

import MLX
import MLXLMCommon
import Foundation

final class KVCacheManager {

    static let shared = KVCacheManager()

    private let activeCache: NSCache<NSString, NSArray> = {
        let cache = NSCache<NSString, NSArray>()
        cache.countLimit = 10
        return cache
    }()
    
    private let cacheDir: URL = {
        
        let url = URL.cachesDirectory.appendingPathComponent("model-cache")
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }()

    // MARK: - Save
    func save(cache: [any KVCache], for key: String) {

        var arrays: [String: MLXArray] = [:]
        
        for (i, layer) in cache.enumerated() {
            let state = layer.state
            MLX.eval(state)
            arrays["k_\(i)"] = state[0]
            arrays["v_\(i)"] = state[1]
        }

        guard !arrays.isEmpty else { return }

        activeCache.setObject(cache as NSArray, forKey: key as NSString)
        let url = cacheDir.appendingPathComponent("\(key).safetensors")

        do {
            try MLX.save(arrays: arrays, url: url)
        } catch {
            print("Cache save failed:", error)
        }
    }

    // MARK: - Load
    func load(for key: String) -> [any KVCache]? {

        if let hit = activeCache.object(forKey: key as NSString) as? [any KVCache] {
            print("Active Cache Hit")
            return hit
        }
        
        let url = cacheDir.appendingPathComponent("\(key).safetensors")

        guard FileManager.default.fileExists(atPath: url.path),
              let dict = try? MLX.loadArrays(url: url)
        else {
            return nil
        }

        let sortedIndices = dict.keys
                .filter { $0.hasPrefix("k_") }
                .compactMap { Int($0.dropFirst(2)) }
                .sorted()

        guard !sortedIndices.isEmpty else { return nil }
        
        var cache: [any KVCache] = []

        for i in sortedIndices {
            guard let k = dict["k_\(i)"],
                  let v = dict["v_\(i)"]
            else {
                return nil
            }

            let layerCache = KVCacheSimple()
            layerCache.state = [k, v]
            cache.append(layerCache)
        }
        activeCache.setObject(cache as NSArray, forKey: key as NSString)
        return cache
    }

    // MARK: - Clear
    func clear(for key: String) {
        let url = cacheDir.appendingPathComponent("\(key).safetensors")
        try? FileManager.default.removeItem(at: url)
    }
}
