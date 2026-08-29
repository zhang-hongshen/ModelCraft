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
