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
        let canonicalTools = canonical(tools)
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
            let entries = dictionary.keys.sorted().map {
                "\(canonical($0))\(canonical(dictionary[$0] as Any))"
            }.joined()
            return "d\(frame(entries))"
        }
        if let array = value as? [any Sendable] {
            return "a\(frame(array.map { canonical($0) }.joined()))"
        }
        if let string = value as? String { return "s\(frame(string))" }
        if let bool = value as? Bool { return bool ? "b1" : "b0" }
        if let number = value as? NSNumber {
            return "n\(frame(String(cString: number.objCType)))\(frame(number.stringValue))"
        }
        if value is NSNull { return "z" }
        return "u\(frame(String(describing: value)))"
    }

    private static func canonical(_ tools: [ToolSpec]) -> String {
        "t\(frame(tools.map { canonical($0) }.joined()))"
    }

    private static func canonical(_ key: String) -> String {
        "k\(frame(key))"
    }

    private static func frame(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }
}
