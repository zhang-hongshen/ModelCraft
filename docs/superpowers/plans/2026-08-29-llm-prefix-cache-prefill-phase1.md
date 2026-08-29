# Text LLM Prefix Cache and Prefill (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reuse exact prepared prompt prefixes and use MLX chunked prefill in `LMService` without changing text-generation quality or the public service API.

**Architecture:** Build a pure prefix planner and deterministic cache-key builder first. Inside the existing `ModelContainer.perform` isolation, prepare the full prompt and optional history prefix, restore or build a complete MLX `KVCache` snapshot, pass only the suffix to `MLXLMCommon.generate`, and hold the runtime lease until the returned stream has finished.

**Tech Stack:** Swift 5.0, Swift Testing, MLX Swift 0.31.3, MLXLMCommon 2.31.3, `ModelContainer`, `TokenIterator`, `KVCacheManager`, CryptoKit SHA-256.

**Spec:** `docs/superpowers/specs/2026-08-29-mlx-runtime-memory-prefill-design.md`

## Global Constraints

- 本轮只优化文本 LLM 路径；MusicGen、Stable Diffusion、MiniMax H3 的模型专属优化仍延期。
- 不增加性能埋点或持久化指标，不改变默认生成质量、采样温度、公开 API 或停止规则。
- 只有完全一致的 prepared token prefix 才能命中 cache；媒体输入、模板不一致、shape 不一致或 cache 读取失败必须走普通 prefill。
- 默认 `GenerateParameters` 使用 `prefillStepSize = 256`，`maxKVSize = nil`，`kvBits = nil`；不强制滑动窗口或量化 cache。
- 不把 `MLXArray`、`LMInput` 或 `[KVCache]` 穿过 actor 边界；所有 cache 读写在 `ModelContainer.perform` 的模型隔离范围内完成。

---

### Task 1: Add pure prefix planning and deterministic cache keys

**Files:**
- Create: `ModelCraft/Services/PromptCacheKey.swift`
- Create: `ModelCraftTests/LLMPrefillTests.swift`
- Modify: `ModelCraft.xcodeproj/project.pbxproj` to register both Swift files in their target phases

**Interfaces:**
- Consumes: prepared token arrays represented as `[Int]`, model identifier, cache format version, and `ToolSpec` dictionaries.
- Produces: `PromptCacheKeyBuilder.make(...)`, `PromptPrefixPlanner.prefixCount(full:prefix:)`, and `PromptPrefixPlanner.suffix(full:prefixCount:)` for `LMService`.

- [ ] **Step 1: Write failing pure-function tests**

Create `ModelCraftTests/LLMPrefillTests.swift`:

```swift
import Testing
@testable import ModelCraft
import MLXLMCommon

struct LLMPrefillTests {
    @Test func prefixPlannerOnlyAcceptsAnExactPrefix() {
        #expect(PromptPrefixPlanner.prefixCount(full: [1, 2, 3, 4], prefix: [1, 2]) == 2)
        #expect(PromptPrefixPlanner.prefixCount(full: [1, 2, 3], prefix: [1, 3]) == nil)
        #expect(PromptPrefixPlanner.prefixCount(full: [1, 2], prefix: [1, 2]) == nil)
        #expect(PromptPrefixPlanner.suffix(full: [1, 2, 3, 4], prefixCount: 2) == [3, 4])
    }

    @Test func promptKeyCanonicalizesToolDictionaryOrder() {
        let first: ToolSpec = [
            "function": [
                "name": "search",
                "parameters": ["type": "object"] as [String: any Sendable],
            ] as [String: any Sendable],
            "type": "function",
        ]
        let second: ToolSpec = [
            "type": "function",
            "function": [
                "parameters": ["type": "object"] as [String: any Sendable],
                "name": "search",
            ] as [String: any Sendable],
        ]

        let lhs = PromptCacheKeyBuilder.make(
            modelID: "model", prefixTokens: [1, 2, 3], tools: [first])
        let rhs = PromptCacheKeyBuilder.make(
            modelID: "model", prefixTokens: [1, 2, 3], tools: [second])
        #expect(lhs == rhs)
    }

    @Test func promptKeyChangesWhenModelOrPrefixChanges() {
        let base = PromptCacheKeyBuilder.make(
            modelID: "model-a", prefixTokens: [1, 2], tools: [])
        let otherModel = PromptCacheKeyBuilder.make(
            modelID: "model-b", prefixTokens: [1, 2], tools: [])
        let otherPrefix = PromptCacheKeyBuilder.make(
            modelID: "model-a", prefixTokens: [1, 3], tools: [])
        #expect(base != otherModel)
        #expect(base != otherPrefix)
    }
}
```

- [ ] **Step 2: Run the focused test and verify the missing-symbol failure**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project ModelCraft.xcodeproj -scheme ModelCraft \
-destination 'platform=macOS' \
-only-testing:ModelCraftTests/LLMPrefillTests test
```

Expected: the test target reports missing `PromptPrefixPlanner` and `PromptCacheKeyBuilder` symbols.

- [ ] **Step 3: Implement the prefix planner**

In `PromptCacheKey.swift`, implement:

```swift
enum PromptPrefixPlanner {
    static func prefixCount(full: [Int], prefix: [Int]) -> Int? {
        guard !prefix.isEmpty, prefix.count < full.count else { return nil }
        guard full.starts(with: prefix) else { return nil }
        return prefix.count
    }

    static func suffix(full: [Int], prefixCount: Int) -> [Int] {
        guard prefixCount >= 0, prefixCount < full.count else { return [] }
        return Array(full[prefixCount...])
    }
}
```

The strict `prefix.count < full.count` rule ensures the downstream generator always receives at least one token after restoring a prefix cache.

- [ ] **Step 4: Implement deterministic tool canonicalization and key building**

Use a recursively sorted representation for `ToolSpec` dictionaries, arrays, strings, booleans, numbers, and `nil`. Include a fixed format version, model ID, canonical tools, and the exact prefix token list in the digest input:

```swift
enum PromptCacheKeyBuilder {
    static let formatVersion = "prompt-cache-v1"

    static func make(
        modelID: String,
        prefixTokens: [Int],
        tools: [ToolSpec]
    ) -> String {
        let canonicalTools = tools.map(canonical).joined(separator: ",")
        let material = [
            formatVersion,
            modelID,
            canonicalTools,
            prefixTokens.map(String.init).joined(separator: ","),
        ].joined(separator: "|")
        return material.sha256String
    }

    private static func canonical(_ value: Any) -> String {
        if let dictionary = value as? [String: any Sendable] {
            return "{" + dictionary.keys.sorted().map {
                "\($0):\(canonical(dictionary[$0] as Any))"
            }.joined(separator: ",") + "}"
        }
        if let array = value as? [any Sendable] {
            return "[" + array.map { canonical($0) }.joined(separator: ",") + "]"
        }
        if let string = value as? String { return "\"\(string)\"" }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let number = value as? NSNumber { return number.stringValue }
        if value is NSNull { return "null" }
        return String(describing: value)
    }
}
```

If a nested `ToolSpec` value cannot be represented by the canonical cases, return its escaped `String(describing:)` value; never use dictionary iteration order as the key material.

- [ ] **Step 5: Run the pure tests**

Run the focused test command again. Expected: all three tests pass. Do not begin `LMService` changes until this helper contract is stable.

---

### Task 2: Integrate exact-prefix cache reuse into LMService

**Files:**
- Modify: `ModelCraft/Services/LMService.swift:20-110`
- Modify: `ModelCraft/Services/KVCacheManager.swift` only if the final method labels differ from the foundation plan

**Interfaces:**
- Consumes: `PromptCacheKeyBuilder`, `PromptPrefixPlanner`, `InferenceRuntimeCoordinator.acquire(_:)`, and `KVCacheManager.cachedCopy(for:)`/`save(cache:for:metadata:)`.
- Produces: the existing `LMService.generate(model:messages:tools:)` stream with safe prefix reuse and `prefillStepSize = 256`.

- [ ] **Step 1: Add a pure suffix-input test seam**

Add this internal helper to `LMService` (or a private extension in `PromptCacheKey.swift`) and test it from `LLMPrefillTests.swift`:

```swift
@inline(__always)
func makeSuffixTokens(fullTokens: MLXArray, prefixCount: Int) -> MLXArray {
    let suffix = fullTokens.flattened().asArray(Int32.self)
    return MLXArray(Array(suffix[prefixCount...])).reshaped(1, -1)
}
```

The test must use `[1, 2, 3, 4]` with `prefixCount = 2`, evaluate the result, and assert `[3, 4]`. This catches accidental slicing of the batch dimension.

- [ ] **Step 2: Run the suffix-input test before integration**

Run the focused `LLMPrefillTests` selection. Expected: the helper is missing.

- [ ] **Step 3: Prepare full and history inputs inside ModelContainer.perform**

Inside the existing `modelContainer.perform { context in ... }` closure:

```swift
var parameters = GenerateParameters(
    temperature: 0.7,
    prefillStepSize: 256)
let fullInput = try await context.processor.prepare(input: userInput)
var generationInput = fullInput
var generationCache: [KVCache]?

let canUsePrefixCache = fullInput.image == nil && fullInput.video == nil && messages.count > 1
if canUsePrefixCache {
    let history = Array(messages.dropLast())
    let historyInput = try await context.processor.prepare(
        input: UserInput(chat: history, tools: tools))
    if historyInput.image == nil && historyInput.video == nil {
        let fullTokens = fullInput.text.tokens.flattened().asArray(Int.self)
        let prefixTokens = historyInput.text.tokens.flattened().asArray(Int.self)
        if let prefixCount = PromptPrefixPlanner.prefixCount(
            full: fullTokens, prefix: prefixTokens)
        {
            let key = PromptCacheKeyBuilder.make(
                modelID: model.id,
                prefixTokens: prefixTokens,
                tools: tools)

            var cache = KVCacheManager.shared.cachedCopy(for: key)
            if cache == nil {
                var built = context.model.newCache(parameters: parameters)
                _ = try TokenIterator(
                    input: historyInput,
                    model: context.model,
                    cache: built,
                    parameters: parameters)
                eval(built)
                KVCacheManager.shared.save(
                    cache: built,
                    for: key,
                    metadata: [
                        "cache_format_version": PromptCacheKeyBuilder.formatVersion,
                        "model_id": model.id,
                        "prefix_token_count": String(prefixCount),
                    ])
                cache = built.map { $0.copy() }
            }

            let suffixTokens = makeSuffixTokens(
                fullTokens: fullInput.text.tokens, prefixCount: prefixCount)
            generationInput = LMInput(
                text: .init(tokens: suffixTokens),
                image: nil,
                video: nil)
            generationCache = cache
        }
    }
}

return try MLXLMCommon.generate(
    input: generationInput,
    cache: generationCache,
    parameters: parameters,
    context: context)
```

Use `historyInput.text.tokens` only as the prefix if it is a strict token prefix of the full prepared input. Do not attempt prefix reuse for images, videos, or empty histories. Passing `generationCache = nil` must preserve the existing normal generation path.

- [ ] **Step 4: Hold the language-model lease through stream completion**

Acquire before `load(model:)`. If loading or preparing throws, release immediately. Once the inner `AsyncStream<Generation>` exists, return a forwarding stream that releases the lease in a `defer` after the inner stream ends:

```swift
let lease = await InferenceRuntimeCoordinator.shared.acquire(.languageModel)
do {
    let modelContainer = try await load(model: model)
    let inner = try await modelContainer.perform { context in
        // prepare fullInput/historyInput and call MLXLMCommon.generate here
    }

    return AsyncStream { continuation in
        let task = Task {
            defer { Task { await lease.release() } }
            for await item in inner {
                if Task.isCancelled { break }
                continuation.yield(item)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
} catch {
    await lease.release()
    throw error
}
```

Keep the existing `AsyncStream<Generation>` return type. The forwarding task is the only owner of the lease after the method returns; early consumer cancellation cancels the forwarding task and its `defer` releases the lease.

- [ ] **Step 5: Keep model capability fallbacks explicit**

Leave `maxKVSize` and `kvBits` as `nil` in this phase. If `cachedCopy` returns a cache whose count, offset, or metadata does not match the freshly created model cache, discard it and call normal `MLXLMCommon.generate` with `generationCache = nil`. Do not call `maybeQuantizeKVCache` globally; most bundled model attention implementations do not support `QuantizedKVCacheProtocol`.

- [ ] **Step 6: Run pure tests and build**

Run `LLMPrefillTests`, then the full `ModelCraftTests` target and the foundation build command. Expected: helper/key tests pass and the app target compiles with the existing stream callers unchanged.

---

### Task 3: Verify the LLM path without adding telemetry

**Files:**
- Inspect: `ModelCraft/Services/LMService.swift`, `ModelCraft/Services/PromptCacheKey.swift`, `ModelCraft/Services/KVCacheManager.swift`
- Modify: none unless a compile-only fix is required

**Interfaces:**
- Consumes: the completed prefix planner, cache manager, and runtime coordinator.
- Produces: a verified text-generation path and a clean handoff for later model-specific work.

- [ ] **Step 1: Run static checks**

Run:

```bash
git diff --check -- ModelCraft/Services/LMService.swift \
ModelCraft/Services/PromptCacheKey.swift \
ModelCraft/Services/KVCacheManager.swift \
ModelCraft/Services/InferenceRuntimeCoordinator.swift \
ModelCraftTests/LLMPrefillTests.swift
```

- [ ] **Step 2: Run focused and full tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project ModelCraft.xcodeproj -scheme ModelCraft \
-destination 'platform=macOS' -only-testing:ModelCraftTests/LLMPrefillTests test

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project ModelCraft.xcodeproj -scheme ModelCraft \
-destination 'platform=macOS' test
```

Expected: both test invocations pass, subject to the environment's existing CoreSimulator service warnings.

- [ ] **Step 3: Run a manual text-generation smoke path**

Use an already downloaded small MLX LLM and send the same multi-message prompt twice. Confirm the second request returns normal `Generation` chunks and that a changed model ID, changed tool schema, media input, or non-prefix history still returns a normal response rather than attempting the stored cache. Do not add timing, memory, OOM, or cache-hit counters to the app.

- [ ] **Step 4: Confirm deferred model scope**

Run:

```bash
git diff -- ModelCraft/Core/Models/MusicGen \
ModelCraft/Core/Models/StableDiffusion \
ModelCraft/Core/Models/MiniMaxH3
```

Expected: no new changes to MusicGen decoder/cross-attention logic, Stable Diffusion denoising/VAE logic, or H3 transformer/conditioning logic beyond the explicitly allowed run-first configuration repair from the foundation plan.

- [ ] **Step 5: Handoff**

Stop after text LLM verification. The next phase may add capability-gated KV quantization or an explicit low-memory sliding-window profile, but neither is enabled by this plan.
