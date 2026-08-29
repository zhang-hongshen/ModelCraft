import Foundation
import MLXLMCommon

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
