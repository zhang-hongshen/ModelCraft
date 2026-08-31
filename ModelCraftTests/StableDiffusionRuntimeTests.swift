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

private final class LifetimeProbe {}

private actor TestGate {
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool {
        continuation != nil
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

@Test
func conditioningKeyIncludesEverySemanticInput() {
    let base = StableDiffusionConditioningKey(
        modelID: "sdxl", prompt: "cat", negativePrompt: "", cfgWeight: 0, imageCount: 1)
    #expect(
        base
            != .init(
                modelID: "other", prompt: "cat", negativePrompt: "", cfgWeight: 0,
                imageCount: 1))
    #expect(
        base
            != .init(
                modelID: "sdxl", prompt: "dog", negativePrompt: "", cfgWeight: 0,
                imageCount: 1))
    #expect(
        base
            != .init(
                modelID: "sdxl", prompt: "cat", negativePrompt: "bad", cfgWeight: 0,
                imageCount: 1))
    #expect(
        base
            != .init(
                modelID: "sdxl", prompt: "cat", negativePrompt: "", cfgWeight: 1,
                imageCount: 1))
    #expect(
        base
            != .init(
                modelID: "sdxl", prompt: "cat", negativePrompt: "", cfgWeight: 0,
                imageCount: 2))
}

@Test
func conditioningCacheKeepsOnlyNewestExactEntry() {
    var cache = StableDiffusionConditioningCache<Int>()
    let first = StableDiffusionConditioningKey(
        modelID: "sdxl", prompt: "cat", negativePrompt: "", cfgWeight: 0, imageCount: 1)
    let second = StableDiffusionConditioningKey(
        modelID: "sdxl", prompt: "dog", negativePrompt: "", cfgWeight: 0, imageCount: 1)
    cache.insert(1, for: first)
    cache.insert(2, for: second)
    #expect(cache.value(for: first) == nil)
    #expect(cache.value(for: second) == 2)
}

@Test
func denoiserRetainsItsDependencyWithoutRetainingTheOwningModel() {
    weak var model: LifetimeProbe?
    weak var dependency: LifetimeProbe?
    var denoiser: StableDiffusionDenoiser?

    do {
        let owningModel = LifetimeProbe()
        let denoiseDependency = LifetimeProbe()
        model = owningModel
        dependency = denoiseDependency
        denoiser = StableDiffusionDenoiser { _, _, _, _, _, _ in
            _ = denoiseDependency
            fatalError("The lifetime probe never invokes denoising")
        }
        withExtendedLifetime(owningModel) {}
    }

    #expect(model == nil)
    #expect(denoiser != nil)
    #expect(dependency != nil)
    denoiser = nil
    #expect(dependency == nil)
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

@Test
func cancelledCachedLoadDoesNotReturnTheCachedValue() async throws {
    let state = StableDiffusionLoadState<Int> { 7 }
    #expect(try await state.load() == 7)

    let gate = TestGate()
    let cancelled = Task {
        await gate.wait()
        return try await state.load()
    }
    while !(await gate.isWaiting) {
        await Task.yield()
    }
    cancelled.cancel()
    await gate.open()

    await #expect(throws: CancellationError.self) {
        try await cancelled.value
    }
}
