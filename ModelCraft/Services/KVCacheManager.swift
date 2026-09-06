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
        let cost: Int
        var lastAccess: UInt64

        init(cache: [any KVCache], cost: Int, lastAccess: UInt64) {
            self.cache = cache
            self.cost = cost
            self.lastAccess = lastAccess
        }
    }

    private let lock = NSLock()
    private let memoryBudget: Int
    private var entries: [String: Entry] = [:]
    private var memoryCost = 0
    private var clock: UInt64 = 0

    init(memoryBudget: Int = 128 * 1024 * 1024) {
        self.memoryBudget = max(0, memoryBudget)
    }

    func save(cache: [any KVCache], for key: String) {
        let snapshot = cache.map { $0.copy() }
        let state = snapshot.flatMap(\.state)
        eval(state)
        let cost = state.reduce(0) { $0 + $1.nbytes }

        lock.lock()
        defer { lock.unlock() }

        removeEntry(for: key)
        entries[key] = Entry(
            cache: snapshot,
            cost: cost,
            lastAccess: nextClockValue())
        memoryCost += cost

        while memoryCost > memoryBudget,
              let oldestKey = entries.min(by: {
                  $0.value.lastAccess < $1.value.lastAccess
              })?.key {
            removeEntry(for: oldestKey)
        }
    }

    func cachedCopy(for key: String) -> [any KVCache]? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = entries[key] else { return nil }
        entry.lastAccess = nextClockValue()
        return entry.cache.map { $0.copy() }
    }

    func clear(for key: String) {
        lock.lock()
        defer { lock.unlock() }
        removeEntry(for: key)
    }

    private func removeEntry(for key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        memoryCost -= entry.cost
    }

    private func nextClockValue() -> UInt64 {
        clock &+= 1
        return clock
    }
}
