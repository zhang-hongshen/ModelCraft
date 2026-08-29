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
    static let templateRevision = "mlx-chat-template-v1"

    static func make(
        modelID: String,
        prefixTokens: [Int],
        tools: [ToolSpec],
        modelRevision: String = "default",
        tokenizerRevision: String = "default",
        templateRevision: String = Self.templateRevision
    ) -> String {
        let canonicalTools = canonical(tools)
        let canonicalTokens = "a\(frame(prefixTokens.map(String.init).joined(separator: ",")))"
        let material = "q" + [
            formatVersion,
            modelID,
            modelRevision,
            tokenizerRevision,
            templateRevision,
            canonicalTools,
            canonicalTokens,
        ]
            .map(frame)
            .joined()
        return material.sha256String
    }

    static func modelRevision(for configuration: ModelConfiguration) -> String {
        switch configuration.id {
        case .id(_, let revision):
            return "hub:\(revision)"
        case .directory(let directory):
            let root = directory.standardizedFileURL
            return "directory:\(root.path):\(directoryFingerprint(root))"
        }
    }

    static func tokenizerRevision(for configuration: ModelConfiguration) -> String {
        let tokenizer = configuration.tokenizerId ?? "default"
        let override = configuration.overrideTokenizer ?? "default"
        return "tokenizer:\(tokenizer)|override:\(override)"
    }

    /// A local Hub directory is mutable even when its model id is unchanged.
    /// Include file identity metadata so replacing weights, tokenizer files,
    /// or chat templates creates a new cache namespace without reading large
    /// safetensor contents on every request.
    private static func directoryFingerprint(_ directory: URL) -> String {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ]
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles])
        var files: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true
            else {
                continue
            }
            let relativePath = url.path.replacingOccurrences(
                of: directory.path + "/", with: "")
            let size = values.fileSize.map(String.init) ?? "-"
            let modified = values.contentModificationDate?.timeIntervalSince1970
                .description ?? "-"
            files.append("\(relativePath)|\(size)|\(modified)")
        }
        return files.sorted().joined(separator: "\n").sha256String
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
