import Foundation
import Testing
@testable import ModelCraft

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.withLock {
            storage += 1
        }
    }

    func incrementAndReturn() -> Int {
        lock.withLock {
            storage += 1
            return storage
        }
    }

    var value: Int {
        lock.withLock { storage }
    }
}

private enum TestLoadError: Error {
    case failed
}

@Test
func sixteenGiBProfileUsesMixedQuantizationWithoutChangingSamplingDefaults() {
    let profile = StableDiffusionRuntimeProfile.recommended(
        physicalMemory: 16 * 1024 * 1024 * 1024)
    #expect(profile.loadConfiguration.float16)
    #expect(profile.loadConfiguration.textEncoderQuantization == .init(groupSize: 64, bits: 4))
    #expect(profile.loadConfiguration.unetQuantization == .init(groupSize: 32, bits: 8))
    let parameters = StableDiffusionConfiguration.presetSDXLTurbo.defaultParameters()
    #expect(parameters.steps == 2)
    #expect(parameters.latentSize == [64, 64])
    #expect(parameters.imageCount == 1)
    #expect(profile.releasesComponentsBetweenStages)
}

@Test
func largerMemoryProfileKeepsFP16WeightsUnquantized() {
    let profile = StableDiffusionRuntimeProfile.recommended(
        physicalMemory: 32 * 1024 * 1024 * 1024)
    #expect(profile.loadConfiguration.float16)
    #expect(profile.loadConfiguration.textEncoderQuantization == nil)
    #expect(profile.loadConfiguration.unetQuantization == nil)
    #expect(!profile.releasesComponentsBetweenStages)
}

@Test
func concurrentModelRequestsShareOneLoad() async throws {
    let counter = LockedCounter()
    let state = StableDiffusionLoadState<Int> {
        counter.increment()
        try await Task.sleep(for: .milliseconds(20))
        return 7
    }

    async let first = state.load()
    async let second = state.load()

    let values = try await [first, second]
    #expect(values == [7, 7])
    #expect(counter.value == 1)
}

@Test
func failedLoadCanRetry() async throws {
    let counter = LockedCounter()
    let state = StableDiffusionLoadState<Int> {
        let attempt = counter.incrementAndReturn()
        if attempt == 1 {
            throw TestLoadError.failed
        }
        return 9
    }

    await #expect(throws: TestLoadError.self) {
        try await state.load()
    }
    #expect(try await state.load() == 9)
    #expect(counter.value == 2)
}

@Test
func cancelledLoadCanRetry() async throws {
    let counter = LockedCounter()
    let state = StableDiffusionLoadState<Int> {
        counter.increment()
        try await Task.sleep(for: .seconds(5))
        return 3
    }

    let first = Task {
        try await state.load()
    }
    while counter.value == 0 {
        await Task.yield()
    }
    first.cancel()
    await #expect(throws: CancellationError.self) {
        try await first.value
    }

    let retry = Task {
        try await state.load()
    }
    while counter.value < 2 {
        await Task.yield()
    }
    retry.cancel()
    await #expect(throws: CancellationError.self) {
        try await retry.value
    }
    #expect(counter.value == 2)
}
