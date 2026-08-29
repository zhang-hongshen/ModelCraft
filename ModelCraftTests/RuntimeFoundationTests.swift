import Testing
import Foundation
import MLX
import MLXLMCommon
@testable import ModelCraft

struct RuntimeFoundationTests {
    @Test func h3ConfigurationInitializerIsConstructible() {
        let configuration = H3Configuration(id: "test/model")
        #expect(configuration.id == "test/model")
        #expect(configuration.task == .fl2va)
    }

    @Test func musicGenPresetsMatchCheckpointDecoderGeometry() {
        let small = MusicGenConfiguration.small.decoderParameters
        #expect(small.bosTokenId == 2048)
        #expect(small.ffnDim == 4096)
        #expect(small.hiddenSize == 1024)
        #expect(small.numAttentionHeads == 16)
        #expect(small.numCodebooks == 4)
        #expect(small.numHiddenLayers == 24)

        let medium = MusicGenConfiguration.medium.decoderParameters
        #expect(medium.bosTokenId == 2048)
        #expect(medium.ffnDim == 6144)
        #expect(medium.hiddenSize == 1536)
        #expect(medium.numAttentionHeads == 24)
        #expect(medium.numCodebooks == 4)
        #expect(medium.numHiddenLayers == 48)

        let large = MusicGenConfiguration.large.decoderParameters
        #expect(large.bosTokenId == 2048)
        #expect(large.ffnDim == 8192)
        #expect(large.hiddenSize == 2048)
        #expect(large.numAttentionHeads == 32)
        #expect(large.numCodebooks == 4)
        #expect(large.numHiddenLayers == 48)
    }

    @Test func coordinatorRunsOnlyOneHeavyLeaseAtATime() async {
        let coordinator = InferenceRuntimeCoordinator(
            profile: .init(cacheLimit: 4 * 1024 * 1024))
        let events = EventRecorder()

        let first = Task {
            try await coordinator.withExclusiveAccess(.languageModel) {
                await events.append("first-enter")
                try await Task.sleep(nanoseconds: 20_000_000)
                await events.append("first-exit")
            }
        }

        try? await Task.sleep(nanoseconds: 1_000_000)
        let second = Task {
            try await coordinator.withExclusiveAccess(.stableDiffusion) {
                await events.append("second-enter")
                await events.append("second-exit")
            }
        }

        _ = try? await first.value
        _ = try? await second.value
        #expect(await events.values() == [
            "first-enter", "first-exit", "second-enter", "second-exit"
        ])
    }

    @Test func cancelledCoordinatorWaiterIsRemovedBeforeNextLease() async throws {
        let coordinator = InferenceRuntimeCoordinator(
            profile: .init(cacheLimit: 4 * 1024 * 1024))
        let first = try await coordinator.acquire(.languageModel)
        let waiting = Task {
            try await coordinator.acquire(.musicGen)
        }

        for _ in 0..<100 {
            if await coordinator.pendingWaiterCount() == 1 { break }
            await Task.yield()
        }
        waiting.cancel()

        do {
            _ = try await waiting.value
            Issue.record("a cancelled waiter must not receive a lease")
        } catch is CancellationError {
            // Expected: cancellation removes the continuation from the queue.
        }

        await first.release()
        let next = try await coordinator.acquire(.stableDiffusion)
        await next.release()
    }

    @Test func promptCacheRoundTripPreservesTypesAndMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manager = KVCacheManager(cacheDirectory: directory, memoryBudget: 8 * 1024 * 1024)
        let keys = MLXArray.ones([1, 2, 3, 4], dtype: .float32)
        let values = MLXArray.zeros([1, 2, 3, 4], dtype: .float32)
        let cache: [any KVCache] = [KVCacheSimple(), RotatingKVCache(maxSize: 16)]
        for item in cache { _ = item.update(keys: keys, values: values) }

        manager.save(cache: cache, for: "unsafe/key", metadata: ["model": "test"])
        manager.removeMemoryCopy(for: "unsafe/key")

        let loaded = try #require(manager.cachedCopy(for: "unsafe/key"))
        #expect(loaded.count == 2)
        #expect(loaded[0] is KVCacheSimple)
        #expect(loaded[1] is RotatingKVCache)
        #expect(loaded[0].offset == 3)
        #expect(loaded[1].offset == 3)
    }

    @Test func promptCacheStoresAnImmutableSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manager = KVCacheManager(cacheDirectory: directory, memoryBudget: 8 * 1024 * 1024)
        let cache: [any KVCache] = [KVCacheSimple()]
        _ = cache[0].update(
            keys: MLXArray.ones([1, 2, 2, 4]), values: MLXArray.zeros([1, 2, 2, 4]))

        manager.save(cache: cache, for: "snapshot")
        _ = cache[0].update(
            keys: MLXArray.ones([1, 2, 2, 4]), values: MLXArray.zeros([1, 2, 2, 4]))

        let loaded = try #require(manager.cachedCopy(for: "snapshot"))
        #expect(loaded[0].offset == 2)
    }

    @Test func promptCacheReturnsIndependentCopies() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = KVCacheManager(cacheDirectory: directory, memoryBudget: 8 * 1024 * 1024)
        let cache: [any KVCache] = [KVCacheSimple()]
        _ = cache[0].update(
            keys: MLXArray.ones([1, 1, 2, 1]), values: MLXArray.zeros([1, 1, 2, 1]))
        manager.save(cache: cache, for: "returned-copy")

        let returned = try #require(manager.cachedCopy(for: "returned-copy"))
        _ = returned[0].update(
            keys: MLXArray.ones([1, 1, 2, 1]), values: MLXArray.zeros([1, 1, 2, 1]))

        let reloaded = try #require(manager.cachedCopy(for: "returned-copy"))
        #expect(reloaded[0].offset == 2)
    }

    @Test func promptCacheRejectsAndDeletesIncompatibleOrCorruptFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = KVCacheManager(cacheDirectory: directory, memoryBudget: 8 * 1024 * 1024)
        let cache: [any KVCache] = [KVCacheSimple()]
        _ = cache[0].update(
            keys: MLXArray.ones([1, 1, 2, 1]), values: MLXArray.zeros([1, 1, 2, 1]))

        let incompatibleURL = manager.fileURL(for: "incompatible")
        try savePromptCache(
            url: incompatibleURL,
            cache: cache,
            metadata: ["cache_format_version": "0"]
        )
        #expect(manager.cachedCopy(for: "incompatible") == nil)
        #expect(!FileManager.default.fileExists(atPath: incompatibleURL.path))

        let corruptURL = manager.fileURL(for: "corrupt")
        try Data("not a safetensors file".utf8).write(to: corruptURL)
        #expect(manager.cachedCopy(for: "corrupt") == nil)
        #expect(!FileManager.default.fileExists(atPath: corruptURL.path))
    }

    @Test func promptCacheClearRemovesOnlyManagedCacheFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = KVCacheManager(cacheDirectory: directory, memoryBudget: 8 * 1024 * 1024)
        let cache: [any KVCache] = [KVCacheSimple()]
        _ = cache[0].update(
            keys: MLXArray.ones([1, 1, 2, 1]), values: MLXArray.zeros([1, 1, 2, 1]))
        manager.save(cache: cache, for: "first")
        manager.save(cache: cache, for: "second")

        let firstURL = manager.fileURL(for: "first")
        let secondURL = manager.fileURL(for: "second")
        let unrelatedURL = directory.appendingPathComponent("keep.txt")
        let unrelatedDirectory = directory.appendingPathComponent("keep.safetensors", isDirectory: true)
        try Data("keep".utf8).write(to: unrelatedURL)
        try FileManager.default.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: unrelatedDirectory.appendingPathComponent("nested.txt"))

        manager.clear(for: "first")
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(manager.cachedCopy(for: "first") == nil)

        manager.clearAll()
        #expect(!FileManager.default.fileExists(atPath: secondURL.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedURL.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedDirectory.path))
        #expect(FileManager.default.fileExists(
            atPath: unrelatedDirectory.appendingPathComponent("nested.txt").path))
    }

    @Test func promptCacheEvictsLeastRecentlyUsedEntryAtByteBudget() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = KVCacheManager(cacheDirectory: directory, memoryBudget: 32)
        let cache: [any KVCache] = [KVCacheSimple()]
        _ = cache[0].update(
            keys: MLXArray.ones([1, 1, 2, 1]), values: MLXArray.zeros([1, 1, 2, 1]))

        manager.save(cache: cache, for: "lru-first")
        manager.save(cache: cache, for: "lru-second")
        _ = try #require(manager.cachedCopy(for: "lru-first"))
        try FileManager.default.removeItem(at: manager.fileURL(for: "lru-second"))

        manager.save(cache: cache, for: "lru-third")

        #expect(manager.cachedCopy(for: "lru-second") == nil)
        #expect(try #require(manager.cachedCopy(for: "lru-first")).count == 1)
        #expect(try #require(manager.cachedCopy(for: "lru-third")).count == 1)
    }

    @Test func promptCacheSaveAfterClearWinsTheDiskOrdering() throws {
        let directory = URL.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = KVCacheManager(cacheDirectory: directory, memoryBudget: 8 * 1024 * 1024)

        let first = [KVCacheSimple() as any KVCache]
        _ = first[0].update(
            keys: MLXArray.ones([1, 1, 1, 1]), values: MLXArray.zeros([1, 1, 1, 1]))
        manager.save(cache: first, for: "ordered")
        manager.clear(for: "ordered")

        let second = [KVCacheSimple() as any KVCache]
        _ = second[0].update(
            keys: MLXArray.ones([1, 1, 2, 1]), values: MLXArray.zeros([1, 1, 2, 1]))
        manager.save(cache: second, for: "ordered")
        manager.removeMemoryCopy(for: "ordered")

        #expect(try #require(manager.cachedCopy(for: "ordered"))[0].offset == 2)
    }

    @Test func promptCacheUsesDigestOnlyDiskPath() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = KVCacheManager(cacheDirectory: directory)

        let url = manager.fileURL(for: "unsafe/key")
        #expect(url.deletingLastPathComponent() == directory)
        #expect(url.lastPathComponent ==
            "6c0df4a253bf45be17e6f86655a16bd208e2fb0d026d2204caaf2be6bcd0addc.safetensors")
    }
}

private actor EventRecorder {
    private var storage: [String] = []
    func append(_ value: String) { storage.append(value) }
    func values() -> [String] { storage }
}
