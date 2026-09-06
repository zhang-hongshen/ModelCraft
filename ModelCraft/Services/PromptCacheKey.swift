import Foundation
import MLXLMCommon
import Tokenizers

enum PromptCacheKey {

    static func make(
        modelID: String,
        modelIdentity: ObjectIdentifier,
        prefixTokens: [Int],
        tools: [ToolSpec]
    ) -> String {
        let tokens = prefixTokens.map(String.init).joined(separator: ",")
        return [
            modelID,
            String(describing: modelIdentity),
            canonical(tools),
            tokens,
        ]
        .map(frame)
        .joined()
        .sha256String
    }

    private static func canonical(_ value: Any) -> String {
        if let dictionary = value as? [String: any Sendable] {
            return "d" + dictionary.keys.sorted().map {
                frame($0) + frame(canonical(dictionary[$0] as Any))
            }.joined()
        }
        if let array = value as? [any Sendable] {
            return "a" + array.map { frame(canonical($0)) }.joined()
        }
        if let string = value as? String { return "s" + frame(string) }
        if let bool = value as? Bool { return bool ? "b1" : "b0" }
        if let number = value as? NSNumber {
            return "n" + frame(String(cString: number.objCType)) + frame(number.stringValue)
        }
        if value is NSNull { return "z" }
        return "u" + frame(String(describing: value))
    }

    private static func canonical(_ tools: [ToolSpec]) -> String {
        tools.map { frame(canonical($0)) }.joined()
    }

    private static func frame(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }
}
