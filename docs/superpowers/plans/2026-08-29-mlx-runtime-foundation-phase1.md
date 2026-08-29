# MLX Runtime Foundation (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stabilize the current ModelCraft MLX runtime, centralize workload admission and memory policy, and make prompt-cache storage correct without changing model inference algorithms.

**Architecture:** Repair the existing H3 configuration/compiler blockers first. Add an actor-based `InferenceRuntimeCoordinator` for one-at-a-time heavy workloads and a lock-protected `KVCacheManager` for non-`Sendable` MLX cache snapshots. Integrate only lifecycle/lease hooks into the existing evaluators; MusicGen, Stable Diffusion, MiniMax H3, and LTX model math remain unchanged.

**Tech Stack:** Swift 5.0, Xcode project target `ModelCraft`, MLX Swift 0.31.3, MLXLMCommon 2.31.3, Swift Testing, macOS 15+.

**Spec:** `docs/superpowers/specs/2026-08-29-mlx-runtime-memory-prefill-design.md`

## Global Constraints

- 本轮实施范围为第 1–5、9–11 节；第 6、7、8 节（MusicGen、Stable Diffusion、MiniMax H3 的模型专属优化）延期。
- 不增加首次加载内存、峰值内存、prefill/decode/采样耗时、OOM 或 cache 错误的运行时记录。
- 默认保持现有生成质量、采样步数、公开 API 和模型权重格式。
- 不把 `MLXArray` 或 `KVCache` 穿过 actor 边界；cache 存储使用锁保护的同步 API。
- 当前工作区已有 H3、VideoTool 和 Stable Diffusion loader 改动，实施时不得回滚、覆盖或把这些既有改动混入无关提交。

---

### Task 1: 修复当前配置与编译阻断

**Files:**
- Modify: `ModelCraft/Core/Models/MiniMaxH3/H3Configuration.swift:87-162`
- Modify: `ModelCraft/Core/Models/MiniMaxH3/H3Loader.swift:371-440`
- Modify: `ModelCraft/Core/Models/MusicGen/MusicGenConfiguration.swift:39-181`
- Create: `ModelCraftTests/RuntimeFoundationTests.swift`
- Modify: `ModelCraft.xcodeproj/project.pbxproj` to add the new test source

**Interfaces:**
- Consumes: the existing `H3Configuration`, `H3Loader.deriveConfig(from:strict:)`, and `MusicGenDecoderParameters` APIs.
- Produces: a constructible `H3Configuration` with a default factory and checkpoint-compatible MusicGen decoder presets. Later tasks rely on these types compiling before touching runtime code.

- [ ] **Step 1: Write the failing configuration tests**

Add this Swift Testing file:

```swift
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
}
```

- [ ] **Step 2: Run the focused tests and verify the current failure**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project ModelCraft.xcodeproj -scheme ModelCraft \
-destination 'platform=macOS' -only-testing:ModelCraftTests/RuntimeFoundationTests test
```

Expected: the H3 initializer does not compile because `factory` is not initialized, and the MusicGen assertions fail against the current positional values.

- [ ] **Step 3: Initialize the H3 factory and complete the loader-derived configuration**

In `H3Configuration`, add a default factory argument and assign it in the initializer:

```swift
public init(
    id: String,
    task: Task = .fl2va,
    files: [H3FileKey: String] = [:],
    defaultParameters: @escaping @Sendable () -> H3GenerationParameters = {
        H3GenerationParameters()
    },
    factory: @escaping @Sendable (HubApi, H3Configuration) throws -> H3Base = {
        hub, configuration in
        try H3Base(hub: hub, configuration: configuration)
    }
) {
    self.id = id
    self.task = task
    self.files = files
    self.defaultParameters = defaultParameters
    self.factory = factory
}
```

In `H3Loader.deriveConfig`, replace the incomplete constructor expression with a real derived configuration:

```swift
var config = H3Configuration(id: "derived")
```

Do not alter tensor mapping, block counting, or H3 inference behavior in this task.

- [ ] **Step 4: Correct only the MusicGen checkpoint geometry**

Replace the three `MusicGenDecoderParameters` initializers with:

```swift
// small
MusicGenDecoderParameters(
    bosTokenId: 2048, ffnDim: 4096, hiddenSize: 1024,
    numAttentionHeads: 16, numCodebooks: 4, numHiddenLayers: 24)

// medium
MusicGenDecoderParameters(
    bosTokenId: 2048, ffnDim: 6144, hiddenSize: 1536,
    numAttentionHeads: 24, numCodebooks: 4, numHiddenLayers: 48)

// large
MusicGenDecoderParameters(
    bosTokenId: 2048, ffnDim: 8192, hiddenSize: 2048,
    numAttentionHeads: 32, numCodebooks: 4, numHiddenLayers: 48)
```

This is a run-first configuration repair, not the deferred MusicGen cross-attention optimization.

- [ ] **Step 5: Run the focused tests and a source build**

Run the focused test command again, then run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project ModelCraft.xcodeproj -scheme ModelCraft -configuration Debug \
-sdk macosx -destination 'generic/platform=macOS' \
-derivedDataPath /private/tmp/ModelCraftDerivedData-foundation \
-disableAutomaticPackageResolution -jobs 1 build
```

Expected: the new configuration tests pass. CoreSimulator warnings are environmental; a source error is a failure.

- [ ] **Step 6: Preserve dirty-file state and record the task boundary**

Run `git diff --check --` on the three modified source files and the test file. Do not stage or commit a dirty H3 file wholesale; if the file already contains user edits, leave it in the worktree and report that the task was validated without a destructive index operation.

---

### Task 2: Add the exclusive MLX runtime coordinator

**Files:**
- Create: `ModelCraft/Services/InferenceRuntimeCoordinator.swift`
- Modify: `ModelCraft.xcodeproj/project.pbxproj` to add the source file to the `Services` group and `ModelCraft` sources phase
- Modify: `ModelCraft/Services/LMService.swift:20-110`
- Modify: `ModelCraft/Core/Models/StableDiffusion/StableDiffusionEvaluator.swift:102-155`
- Modify: `ModelCraft/Core/Models/MusicGen/MusicGenEvaluator.swift:13-57`
- Modify: `ModelCraft/Core/Models/MiniMaxH3/H3Evaluator.swift:314-330` (lease wrapper only; preserve surrounding dirty changes)
- Modify: `ModelCraft/Core/Models/LTXVideo/LTXVideoEvaluator.swift:1-75`

**Interfaces:**
- Consumes: MLX `Memory.cacheLimit`, existing evaluator/factory `load()` methods, and `AsyncStream`/`AsyncThrowingStream` lifecycles.
- Produces: `InferenceRuntimeCoordinator.acquire(_:)`, `InferenceRuntimeCoordinator.release(_:)`, and `InferenceRuntimeCoordinator.withExclusiveAccess(_:_:)` for later LLM/cache integration.

- [ ] **Step 1: Write the coordinator serialization test**

Append the following test to `RuntimeFoundationTests.swift`:

```swift
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

private actor EventRecorder {
    private var storage: [String] = []
    func append(_ value: String) { storage.append(value) }
    func values() -> [String] { storage }
}
```

- [ ] **Step 2: Run the coordinator test and verify it fails to compile**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project ModelCraft.xcodeproj -scheme ModelCraft \
-destination 'platform=macOS' -only-testing:ModelCraftTests/RuntimeFoundationTests test
```

Expected: `InferenceRuntimeCoordinator` and `EventRecorder` are not defined yet.

- [ ] **Step 3: Implement the coordinator and lease types**

Create `InferenceRuntimeCoordinator.swift` with this contract:

```swift
import Foundation
import MLX

struct InferenceMemoryProfile: Sendable, Equatable {
    let cacheLimit: Int

    init(cacheLimit: Int) {
        self.cacheLimit = max(0, cacheLimit)
    }

    static var deviceDefault: InferenceMemoryProfile {
        let sixteenGB = 18_000_000_000
        let limit = ProcessInfo.processInfo.physicalMemory <= sixteenGB
            ? 128 * 1024 * 1024
            : 256 * 1024 * 1024
        return .init(cacheLimit: limit)
    }
}

enum InferenceWorkload: String, Sendable {
    case languageModel
    case stableDiffusion
    case musicGen
    case miniMaxH3
    case ltxVideo
}

struct InferenceLease: Sendable {
    fileprivate let id: UUID
    fileprivate let coordinator: InferenceRuntimeCoordinator

    func release() async {
        await coordinator.release(id: id)
    }
}

actor InferenceRuntimeCoordinator {
    static let shared = InferenceRuntimeCoordinator()

    let profile: InferenceMemoryProfile
    private var activeLease: UUID?
    private var waiters: [(UUID, InferenceWorkload, CheckedContinuation<InferenceLease, Never>)] = []

    init(profile: InferenceMemoryProfile = .deviceDefault) {
        self.profile = profile
    }

    func acquire(_ workload: InferenceWorkload) async -> InferenceLease {
        let id = UUID()
        if activeLease == nil {
            activeLease = id
            applyMemoryProfile()
            return InferenceLease(id: id, coordinator: self)
        }

        return await withCheckedContinuation { continuation in
            waiters.append((id, workload, continuation))
        }
    }

    func release(id: UUID) {
        guard activeLease == id else { return }
        guard !waiters.isEmpty else {
            activeLease = nil
            return
        }

        let (nextID, _, continuation) = waiters.removeFirst()
        activeLease = nextID
        applyMemoryProfile()
        continuation.resume(returning: InferenceLease(id: nextID, coordinator: self))
    }

    func withExclusiveAccess<T: Sendable>(
        _ workload: InferenceWorkload,
        _ operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        let lease = await acquire(workload)
        do {
            let value = try await operation()
            await lease.release()
            return value
        } catch {
            await lease.release()
            throw error
        }
    }

    private func applyMemoryProfile() {
        if Memory.cacheLimit > profile.cacheLimit {
            Memory.cacheLimit = profile.cacheLimit
        }
    }
}
```

`release(id:)` is idempotent for stale/double termination callbacks. Do not add counters or timing fields.

- [ ] **Step 4: Register the new source in the Xcode target**

Add one `PBXFileReference` and one `PBXBuildFile` for `InferenceRuntimeCoordinator.swift`, place the file reference beside `KVCacheManager.swift` and `LMService.swift` under the `Services` group, and add the build file to `70CE60602BAD2D4500A2D0B0 /* Sources */`. Keep existing project UUIDs and file ordering otherwise unchanged.

- [ ] **Step 5: Remove competing factory-level cache-limit writes**

Delete only the `Memory.cacheLimit = ...` and `Memory.memoryLimit = ...` assignments from the initializers of the Stable Diffusion, MusicGen, and LTX factories. Leave their existing `conserveMemory` booleans and all model behavior untouched; the coordinator now applies the process-wide cache cap when a workload starts.

- [ ] **Step 6: Hold leases for complete workload lifetimes**

Use `await InferenceRuntimeCoordinator.shared.acquire(...)` before loading in stream-returning methods and release from a `defer` inside the forwarding task. For value-returning methods whose result is `MLXArray` and therefore must not cross an actor generic boundary, use the explicit lease pattern:

```swift
let lease = await InferenceRuntimeCoordinator.shared.acquire(.musicGen)
do {
    let model = try await modelFactory.load()
    let result = model.generate(parameters)
    await lease.release()
    return result
} catch {
    await lease.release()
    throw error
}
```

Apply the same pattern to H3 and LTX. In `LMService`, hold the language-model lease until the returned `AsyncStream` forwarding task finishes. In Stable Diffusion, hold the lease until the `AsyncThrowingStream` task finishes or is cancelled. Do not alter denoise, sampling, VAE, or transformer code.

- [ ] **Step 7: Run coordinator tests and build**

Run the focused test command, then the foundation build command from Task 1. Expected: the coordinator test passes and no source changes appear under the deferred model-optimization sections.

---

### Task 3: Replace the mutable two-array cache manager

**Files:**
- Modify: `ModelCraft/Services/KVCacheManager.swift:1-112`
- Modify: `ModelCraftTests/RuntimeFoundationTests.swift`

**Interfaces:**
- Consumes: MLXLMCommon `KVCache.copy()`, `savePromptCache(url:cache:metadata:)`, `loadPromptCache(url:)`, and `MLXArray.nbytes`.
- Produces: `KVCacheManager.save(cache:for:metadata:)`, `KVCacheManager.cachedCopy(for:)`, `KVCacheManager.load(for:into:)`, `KVCacheManager.clear(for:)`, and `KVCacheManager.clearAll()` with the existing singleton preserved.

- [ ] **Step 1: Write failing cache round-trip and isolation tests**

Append these tests:

```swift
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
```

- [ ] **Step 2: Run the focused tests and verify the current manager fails**

Run the `RuntimeFoundationTests` test selection. Expected: the initializer and `cachedCopy`/`removeMemoryCopy` APIs are missing; the existing manager also cannot preserve rotating-cache metadata.

- [ ] **Step 3: Implement a lock-protected snapshot store**

Replace the `NSCache<NSString, NSArray>` and raw `k_i`/`v_i` serialization with these implementation rules:

```swift
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
}
```

`save` must copy every cache with `copy()`, evaluate the copied state, compute `state.reduce(0) { $0 + $1.nbytes }`, insert the entry under the lock, and evict the least-recently-used entries until `memoryCost <= memoryBudget`. It must call `savePromptCache` with a metadata dictionary containing `cache_format_version = "1"` plus caller metadata. The on-disk URL is `cacheDirectory.appendingPathComponent(key.sha256String).appendingPathExtension("safetensors")`; never append the raw key.

`cachedCopy(for:)` must first return a fresh copy of the in-memory snapshot. On a miss, it must call `loadPromptCache`, reject a missing or mismatched `cache_format_version`, copy the loaded cache into memory, and return another fresh copy. Corrupt or incompatible files are removed and treated as misses. `load(for:into:)` assigns a copied loaded array to the inout argument only when the cache is non-empty. `clear(for:)` removes both the dictionary entry and digest file; `clearAll()` removes all entries and only files in the configured cache directory. Keep the methods synchronous because MLXArray is not `Sendable`.

- [ ] **Step 4: Add the immutable snapshot and disk-path helpers**

Implement `removeMemoryCopy(for:)` as an internal test-only helper that removes only the in-memory entry. Add an internal `fileURL(for:)` helper so tests can verify the digest path without depending on private storage. Do not expose cache metadata or memory counters as runtime telemetry.

- [ ] **Step 5: Run cache tests, then run the full ModelCraftTests target**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project ModelCraft.xcodeproj -scheme ModelCraft \
-destination 'platform=macOS' -only-testing:ModelCraftTests/RuntimeFoundationTests test
```

Expected: both cache tests pass, including after the original cache is mutated. Then run the complete `ModelCraftTests` target to catch source-registration or concurrency regressions.

---

### Task 4: Foundation verification and handoff

**Files:**
- Modify: none unless a build-only fix is required by Tasks 1–3
- Inspect: `ModelCraft/Services/InferenceRuntimeCoordinator.swift`, `ModelCraft/Services/KVCacheManager.swift`, `ModelCraft/Services/LMService.swift`

**Interfaces:**
- Consumes: the completed coordinator and cache manager APIs.
- Produces: a clean foundation checkpoint for the separate text-LLM prefill plan.

- [ ] **Step 1: Run static checks**

Run:

```bash
git diff --check -- ModelCraft/Services/KVCacheManager.swift \
ModelCraft/Services/InferenceRuntimeCoordinator.swift \
ModelCraft/Services/LMService.swift \
ModelCraft/Core/Models/MiniMaxH3/H3Configuration.swift \
ModelCraft/Core/Models/MiniMaxH3/H3Loader.swift \
ModelCraft/Core/Models/MusicGen/MusicGenConfiguration.swift \
ModelCraft/Core/Models/StableDiffusion/StableDiffusionEvaluator.swift \
ModelCraft/Core/Models/MusicGen/MusicGenEvaluator.swift \
ModelCraft/Core/Models/MiniMaxH3/H3Evaluator.swift \
ModelCraft/Core/Models/LTXVideo/LTXVideoEvaluator.swift
```

- [ ] **Step 2: Build with the same DerivedData directory used for incremental verification**

Run the Task 1 build command with `-derivedDataPath /private/tmp/ModelCraftDerivedData-foundation`. Report `BUILD SUCCEEDED` separately from pre-existing CoreSimulator or Sendable warnings.

- [ ] **Step 3: Verify the deferred scope**

Run:

```bash
git diff -- ModelCraft/Core/Models/MusicGen/MusicGen.swift \
ModelCraft/Core/Models/StableDiffusion/StableDiffusion.swift \
ModelCraft/Core/Models/MiniMaxH3/H3Base.swift \
ModelCraft/Core/Models/MiniMaxH3/H3OmniTransformer.swift
```

Expected: no new algorithmic changes from this phase. Any differences in those files must be pre-existing user changes, not introduced by this plan.

- [ ] **Step 4: Stop at the foundation checkpoint**

Do not begin the text LLM prefill task until the foundation build and cache tests have passed; do not begin deferred sections 6–8 in this phase.
