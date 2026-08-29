import Testing
@testable import ModelCraft
import MLXLMCommon

private struct UnsupportedToolValue: Sendable, CustomStringConvertible {
    let description: String
}

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

    @Test func prefixPlannerGuardsEmptyAndOverlongPrefixes() {
        #expect(PromptPrefixPlanner.prefixCount(full: [1, 2], prefix: []) == nil)
        #expect(PromptPrefixPlanner.prefixCount(full: [1, 2], prefix: [1, 2, 3]) == nil)
        #expect(PromptPrefixPlanner.suffix(full: [1, 2], prefixCount: -1) == [])
        #expect(PromptPrefixPlanner.suffix(full: [1, 2], prefixCount: 2) == [])
    }
}
