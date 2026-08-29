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
}

private actor EventRecorder {
    private var storage: [String] = []
    func append(_ value: String) { storage.append(value) }
    func values() -> [String] { storage }
}
