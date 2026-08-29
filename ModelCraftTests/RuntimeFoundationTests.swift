import Testing
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
}

private actor EventRecorder {
    private var storage: [String] = []
    func append(_ value: String) { storage.append(value) }
    func values() -> [String] { storage }
}
