import Testing
@testable import ModelCraft
import Foundation
import MLX
import MLXLMCommon

private struct UnsupportedToolValue: Sendable, CustomStringConvertible {
    let description: String
}

struct LLMPrefillTests {
    @Test func prefixCacheMetadataRequiresMatchingIdentityAndStateSignature() {
        let metadata = [
            "cache_format_version": "1",
            "prompt_cache_format_version": PromptCacheKeyBuilder.formatVersion,
            "model_id": "model-id",
            "prefix_token_count": "2",
            "cache_state_signature": "state-signature",
        ]

        #expect(PromptCacheMetadata.matches(
            metadata,
            modelID: "model-id",
            prefixCount: 2,
            stateSignature: "state-signature"))
        #expect(!PromptCacheMetadata.matches(
            metadata,
            modelID: "other-model",
            prefixCount: 2,
            stateSignature: "state-signature"))
        #expect(!PromptCacheMetadata.matches(
            metadata,
            modelID: "model-id",
            prefixCount: 3,
            stateSignature: "state-signature"))
        #expect(!PromptCacheMetadata.matches(
            metadata,
            modelID: "model-id",
            prefixCount: 2,
            stateSignature: "other-signature"))

        var unsupportedManagerFormat = metadata
        unsupportedManagerFormat["cache_format_version"] = "0"
        #expect(!PromptCacheMetadata.matches(
            unsupportedManagerFormat,
            modelID: "model-id",
            prefixCount: 2,
            stateSignature: "state-signature"))

        var unsupportedPromptFormat = metadata
        unsupportedPromptFormat["prompt_cache_format_version"] = "prompt-cache-v0"
        #expect(!PromptCacheMetadata.matches(
            unsupportedPromptFormat,
            modelID: "model-id",
            prefixCount: 2,
            stateSignature: "state-signature"))
    }

    @Test func cacheStateSignatureChangesWithSavedTensorShape() {
        let first: [any KVCache] = [KVCacheSimple()]
        _ = first[0].update(
            keys: MLXArray.ones([1, 1, 2, 4]),
            values: MLXArray.ones([1, 1, 2, 4]))
        let second: [any KVCache] = [KVCacheSimple()]
        _ = second[0].update(
            keys: MLXArray.ones([1, 1, 3, 4]),
            values: MLXArray.ones([1, 1, 3, 4]))

        eval(first, second)
        #expect(KVCacheManager.stateSignature(for: first) != KVCacheManager.stateSignature(for: second))
    }

    @Test func cachedSnapshotCarriesSavedMetadataWithItsCacheCopy() {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = KVCacheManager(cacheDirectory: directory)
        defer {
            manager.clearAll()
            try? FileManager.default.removeItem(at: directory)
        }

        let cache: [any KVCache] = [KVCacheSimple()]
        _ = cache[0].update(
            keys: MLXArray.ones([1, 1, 2, 4]),
            values: MLXArray.ones([1, 1, 2, 4]))
        eval(cache)
        manager.save(cache: cache, for: "record", metadata: ["model_id": "model-id"])

        let snapshot = manager.cachedSnapshot(for: "record")
        #expect(snapshot != nil)
        guard let snapshot else { return }
        #expect(snapshot.metadata["cache_format_version"] == "1")
        #expect(snapshot.metadata["model_id"] == "model-id")
        #expect(snapshot.metadata["cache_state_signature"] == KVCacheManager.stateSignature(for: snapshot.cache))
    }

    @Test func suffixTokensSliceTheFlattenedTokenSequence() {
        let fullTokens = MLXArray([1, 2, 3, 4]).reshaped(1, -1)
        let suffix = makeSuffixTokens(fullTokens: fullTokens, prefixCount: 2)

        eval(suffix)
        #expect(suffix.flattened().asArray(Int32.self) == [3, 4])
    }

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

    @Test func promptKeySeparatesDelimiterAndQuoteContent() {
        let first: ToolSpec = ["value": "a|b,c"]
        let second: ToolSpec = ["value": "a", "b,c": ""]
        let firstKey = PromptCacheKeyBuilder.make(modelID: "model|x", prefixTokens: [1, 2], tools: [first])
        let secondKey = PromptCacheKeyBuilder.make(modelID: "model", prefixTokens: [1, 2], tools: [second])
        #expect(firstKey != secondKey)
    }

    @Test func promptKeyPreservesRecursiveArrayOrderAndScalarTypes() {
        let ordered: ToolSpec = [
            "value": ["first", ["second", "third"]] as [any Sendable],
        ]
        let reversed: ToolSpec = [
            "value": ["first", ["third", "second"]] as [any Sendable],
        ]
        let orderedKey = PromptCacheKeyBuilder.make(modelID: "model", prefixTokens: [1], tools: [ordered])
        let reversedKey = PromptCacheKeyBuilder.make(modelID: "model", prefixTokens: [1], tools: [reversed])
        #expect(orderedKey != reversedKey)

        let boolKey = PromptCacheKeyBuilder.make(modelID: "model", prefixTokens: [1], tools: [["value": true]])
        let numberKey = PromptCacheKeyBuilder.make(modelID: "model", prefixTokens: [1], tools: [["value": 1]])
        let nullKey = PromptCacheKeyBuilder.make(modelID: "model", prefixTokens: [1], tools: [["value": NSNull()]])
        #expect(boolKey != numberKey)
        #expect(boolKey != nullKey)
        #expect(numberKey != nullKey)
    }

    @Test func promptKeyEscapesUnsupportedFallbackValues() {
        let first: ToolSpec = ["value": UnsupportedToolValue(description: "x|y,z\"q")]
        let second: ToolSpec = ["value": UnsupportedToolValue(description: "x|y"), "z,q\"x": ""]
        let firstKey = PromptCacheKeyBuilder.make(modelID: "model", prefixTokens: [1], tools: [first])
        let secondKey = PromptCacheKeyBuilder.make(modelID: "model", prefixTokens: [1], tools: [second])
        #expect(firstKey != secondKey)
    }

    @Test func promptKeyFramesTopLevelTupleBoundaries() {
        let first = PromptCacheKeyBuilder.make(
            modelID: "model|with|delimiters", prefixTokens: [1, 23], tools: [])
        let second = PromptCacheKeyBuilder.make(
            modelID: "model", prefixTokens: [1, 2, 3], tools: [["name": "with|delimiters"]])
        #expect(first != second)
    }

    @Test func prefixPlannerGuardsEmptyAndOverlongPrefixes() {
        #expect(PromptPrefixPlanner.prefixCount(full: [1, 2], prefix: []) == nil)
        #expect(PromptPrefixPlanner.prefixCount(full: [1, 2], prefix: [1, 2, 3]) == nil)
        #expect(PromptPrefixPlanner.suffix(full: [1, 2], prefixCount: -1) == [])
        #expect(PromptPrefixPlanner.suffix(full: [1, 2], prefixCount: 2) == [])
    }
}
