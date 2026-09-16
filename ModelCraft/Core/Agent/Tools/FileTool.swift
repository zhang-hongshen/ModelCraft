//
//  FileTool.swift
//  ModelCraft
//
//  Created by Hongshen on 26/1/26.
//

import Foundation
import MLXLMCommon

enum FileTool {

    static let allTools: [any ToolProtocol] = [
        readFile,
        applyPatch,
        listDirectory
    ]

    static func readFile(_ path: String) throws -> String {
        try Task.checkCancellation()

        let url = fileURL(for: path)
        let data = try Data(contentsOf: url)

        try Task.checkCancellation()
        return String(decoding: data, as: UTF8.self)
    }

    static func listDirectory(_ path: String) throws -> [DirectoryEntry] {
        try Task.checkCancellation()

        let url = fileURL(for: path)
        return try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).map { itemURL in
            try Task.checkCancellation()
            return DirectoryEntry(
                name: itemURL.lastPathComponent,
                path: itemURL.path,
                isDirectory: try itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            )
        }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func applyPatch(_ patch: String) throws -> [String] {
        try Task.checkCancellation()

        let operations = try PatchParser.parse(patch)
        var staged: [URL: String?] = [:]
        var changedPaths: [String] = []

        for operation in operations {
            try Task.checkCancellation()

            switch operation {
            case .add(let path, let content):
                let url = fileURL(for: path)
                try ensureWritable(url)

                guard staged[url] == nil, !FileManager.default.fileExists(atPath: url.path) else {
                    throw FileToolError.fileAlreadyExists(path)
                }

                staged[url] = content
                changedPaths.append(path)

            case .update(let path, let chunks):
                let url = fileURL(for: path)
                try ensureWritable(url)

                let current: String
                if let stagedValue = staged[url] {
                    guard let stagedValue else {
                        throw FileToolError.fileNotFound(path)
                    }
                    current = stagedValue
                } else {
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        throw FileToolError.fileNotFound(path)
                    }
                    current = try readFile(path)
                }

                staged[url] = try PatchApplier.apply(chunks, to: current, path: path)
                if !changedPaths.contains(path) {
                    changedPaths.append(path)
                }

            case .delete(let path):
                let url = fileURL(for: path)
                try ensureWritable(url)

                if let stagedValue = staged[url] {
                    guard stagedValue != nil else {
                        throw FileToolError.fileNotFound(path)
                    }
                } else {
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        throw FileToolError.fileNotFound(path)
                    }
                }

                staged[url] = .some(nil)
                if !changedPaths.contains(path) {
                    changedPaths.append(path)
                }
            }
        }

        // Validate every operation first, then mutate the filesystem.
        for (url, content) in staged {
            try Task.checkCancellation()

            if let content {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(content.utf8).write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }

        try Task.checkCancellation()
        return changedPaths
    }

    static func fileURL(for path: String) -> URL {
        URL(
            fileURLWithPath: path,
            relativeTo: ProjectToolContext.workingDirectory ?? .documentsDirectory
        ).standardizedFileURL
    }

    private static func ensureWritable(_ url: URL) throws {
        let candidate = url.resolvingSymlinksInPath()
        let workingDirectory = ProjectToolContext.workingDirectory?.resolvingSymlinksInPath()

        if let workingDirectory {
            guard candidate.pathComponents.starts(with: workingDirectory.pathComponents) else {
                throw FileToolError.outsideWorkingDirectory
            }
            return
        }

        if ProjectToolContext.readOnlyFiles.contains(where: {
            $0.resolvingSymlinksInPath() == candidate
        }) {
            throw FileToolError.readOnlyReference
        }
    }

    static let readFile = Tool<ReadFileInput, ReadFileOutput>(
        name: ToolNames.readFile,
        description: "Reads text from a file. Relative paths resolve from the current project's working folder, or the app's Documents directory when no working folder is configured. Returns the complete file unless a line range is specified.",
        parameters: [
            .required("path", type: .string, description: "The absolute path, or a path relative to the current project's working folder (Documents when no working folder is configured)."),
            .optional("start_line", type: .int, description: "The first line to return, starting from 1."),
            .optional("line_count", type: .int, description: "The maximum number of lines to return.")
        ]
    ) { input in
        let content = try FileTool.readFile(input.path)

        guard input.startLine != nil || input.lineCount != nil else {
            return ReadFileOutput(content: content)
        }

        let startLine = input.startLine ?? 1
        guard startLine > 0, input.lineCount.map({ $0 > 0 }) ?? true else {
            throw FileToolError.invalidLineRange
        }

        let lines = content.components(separatedBy: "\n")
        guard startLine <= lines.count else {
            throw FileToolError.lineOutOfRange
        }

        let startIndex = startLine - 1
        let endIndex = input.lineCount.map {
            startIndex + min($0, lines.count - startIndex)
        } ?? lines.count

        return ReadFileOutput(
            content: lines[startIndex..<endIndex].joined(separator: "\n")
        )
    }

    static let applyPatch = Tool<ApplyPatchInput, ApplyPatchOutput>(
        name: ToolNames.applyPatch,
        description: """
        Applies a patch to files in the current project's working folder. Use this for all file creation, modification, and deletion.

        Patch format:
        *** Begin Patch
        *** Add File: path
        +new file content
        *** Update File: path
        @@ optional context
         unchanged line
        -old line
        +new line
        *** Delete File: path
        *** End Patch

        Multiple files and multiple update chunks may be included in one patch. Update chunks must match exactly once. The patch is fully validated before any file is changed.
        """,
        parameters: [
            .required("patch", type: .string, description: "The complete apply_patch document.")
        ]
    ) { input in
        let paths = try FileTool.applyPatch(input.patch)
        return ApplyPatchOutput(success: true, paths: paths)
    }

    static let listDirectory = Tool<ListDirectoryInput, ListDirectoryOutput>(
        name: ToolNames.listDirectory,
        description: "List the direct children of one local directory without recursively reading descendants. Relative paths resolve from the current project's working folder, or Documents when no working folder is configured. Returns each child's name, path, and whether it is a directory.",
        parameters: [
            .optional("path", type: .string, description: "The absolute path, or a path relative to the current project's working folder (Documents when no working folder is configured). Omit it to list that default directory.")
        ]
    ) { input in
        let entries = try FileTool.listDirectory(input.path ?? "")
        return ListDirectoryOutput(entries: entries)
    }
}

private enum PatchOperation {
    case add(path: String, content: String)
    case update(path: String, chunks: [PatchChunk])
    case delete(path: String)
}

private struct PatchChunk {
    let context: String?
    let lines: [PatchLine]
}

private enum PatchLine {
    case context(String)
    case remove(String)
    case add(String)
}

private enum PatchParser {

    static func parse(_ patch: String) throws -> [PatchOperation] {
        let lines = patch.components(separatedBy: "\n")

        guard lines.first == "*** Begin Patch",
              lines.last == "*** End Patch" else {
            throw FileToolError.invalidPatch("Patch must start with '*** Begin Patch' and end with '*** End Patch'.")
        }

        var index = 1
        var operations: [PatchOperation] = []

        while index < lines.count - 1 {
            let line = lines[index]

            if line.hasPrefix("*** Add File: ") {
                let path = String(line.dropFirst("*** Add File: ".count))
                guard !path.isEmpty else {
                    throw FileToolError.invalidPatch("Add File path is empty.")
                }

                index += 1
                var contentLines: [String] = []

                while index < lines.count - 1, !lines[index].hasPrefix("*** ") {
                    guard lines[index].hasPrefix("+") else {
                        throw FileToolError.invalidPatch("Every Add File content line must start with '+'.")
                    }
                    contentLines.append(String(lines[index].dropFirst()))
                    index += 1
                }

                operations.append(.add(path: path, content: contentLines.joined(separator: "\n")))
                continue
            }

            if line.hasPrefix("*** Delete File: ") {
                let path = String(line.dropFirst("*** Delete File: ".count))
                guard !path.isEmpty else {
                    throw FileToolError.invalidPatch("Delete File path is empty.")
                }

                operations.append(.delete(path: path))
                index += 1
                continue
            }

            if line.hasPrefix("*** Update File: ") {
                let path = String(line.dropFirst("*** Update File: ".count))
                guard !path.isEmpty else {
                    throw FileToolError.invalidPatch("Update File path is empty.")
                }

                index += 1
                var chunks: [PatchChunk] = []

                while index < lines.count - 1, !lines[index].hasPrefix("*** ") {
                    guard lines[index].hasPrefix("@@") else {
                        throw FileToolError.invalidPatch("Update File chunks must start with '@@'.")
                    }

                    let header = String(lines[index].dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    let context = header.isEmpty ? nil : header
                    index += 1

                    var patchLines: [PatchLine] = []
                    while index < lines.count - 1,
                          !lines[index].hasPrefix("@@"),
                          !lines[index].hasPrefix("*** ") {
                        let patchLine = lines[index]

                        guard let marker = patchLine.first else {
                            throw FileToolError.invalidPatch("Update lines must start with ' ', '-' or '+'.")
                        }

                        let text = String(patchLine.dropFirst())
                        switch marker {
                        case " ":
                            patchLines.append(.context(text))
                        case "-":
                            patchLines.append(.remove(text))
                        case "+":
                            patchLines.append(.add(text))
                        default:
                            throw FileToolError.invalidPatch("Update lines must start with ' ', '-' or '+'.")
                        }

                        index += 1
                    }

                    guard patchLines.contains(where: {
                        if case .remove = $0 { return true }
                        if case .add = $0 { return true }
                        return false
                    }) else {
                        throw FileToolError.invalidPatch("Update chunk contains no changes.")
                    }

                    chunks.append(PatchChunk(context: context, lines: patchLines))
                }

                guard !chunks.isEmpty else {
                    throw FileToolError.invalidPatch("Update File contains no chunks.")
                }

                operations.append(.update(path: path, chunks: chunks))
                continue
            }

            throw FileToolError.invalidPatch("Unknown patch directive: \(line)")
        }

        guard !operations.isEmpty else {
            throw FileToolError.invalidPatch("Patch contains no operations.")
        }

        return operations
    }
}

private enum PatchApplier {

    static func apply(_ chunks: [PatchChunk], to content: String, path: String) throws -> String {
        var lines = content.components(separatedBy: "\n")

        for chunk in chunks {
            let oldLines = chunk.lines.compactMap { line -> String? in
                switch line {
                case .context(let text), .remove(let text):
                    return text
                case .add:
                    return nil
                }
            }

            let newLines = chunk.lines.compactMap { line -> String? in
                switch line {
                case .context(let text), .add(let text):
                    return text
                case .remove:
                    return nil
                }
            }

            guard !oldLines.isEmpty else {
                throw FileToolError.invalidPatch("Update chunk for '\(path)' has no matchable context.")
            }

            let searchStart: Int
            if let context = chunk.context {
                guard let anchor = lines.firstIndex(where: { $0.contains(context) }) else {
                    throw FileToolError.patchContextNotFound(path: path, context: context)
                }
                searchStart = anchor
            } else {
                searchStart = 0
            }

            let matches = matchingRanges(of: oldLines, in: lines, startingAt: searchStart)

            guard matches.count == 1, let range = matches.first else {
                throw FileToolError.patchExpectedOneMatch(
                    path: path,
                    actual: matches.count
                )
            }

            lines.replaceSubrange(range, with: newLines)
        }

        return lines.joined(separator: "\n")
    }

    private static func matchingRanges(
        of needle: [String],
        in haystack: [String],
        startingAt start: Int
    ) -> [Range<Int>] {
        guard !needle.isEmpty, haystack.count >= needle.count, start < haystack.count else {
            return []
        }

        let lastStart = haystack.count - needle.count
        guard start <= lastStart else {
            return []
        }

        var matches: [Range<Int>] = []

        for index in start...lastStart {
            let range = index..<(index + needle.count)
            if Array(haystack[range]) == needle {
                matches.append(range)
            }
        }

        return matches
    }
}

enum FileToolError: LocalizedError {
    case outsideWorkingDirectory
    case readOnlyReference
    case invalidLineRange
    case lineOutOfRange
    case invalidPatch(String)
    case fileAlreadyExists(String)
    case fileNotFound(String)
    case patchContextNotFound(path: String, context: String)
    case patchExpectedOneMatch(path: String, actual: Int)

    var errorDescription: String? {
        switch self {
        case .outsideWorkingDirectory:
            "Files outside the project's working folder cannot be changed."
        case .readOnlyReference:
            "Project reference files are read-only."
        case .invalidLineRange:
            "start_line and line_count must be greater than zero."
        case .lineOutOfRange:
            "start_line is beyond the end of the file."
        case .invalidPatch(let message):
            "Invalid patch: \(message)"
        case .fileAlreadyExists(let path):
            "Cannot add '\(path)' because the file already exists."
        case .fileNotFound(let path):
            "Cannot modify '\(path)' because the file does not exist."
        case .patchContextNotFound(let path, let context):
            "Could not find patch context '\(context)' in '\(path)'."
        case .patchExpectedOneMatch(let path, let actual):
            "Expected patch chunk in '\(path)' to match exactly once, but found \(actual) matches."
        }
    }
}

struct ReadFileInput: Codable {
    let path: String
    let startLine: Int?
    let lineCount: Int?

    enum CodingKeys: String, CodingKey {
        case path
        case startLine = "start_line"
        case lineCount = "line_count"
    }
}

struct ReadFileOutput: Codable {
    let content: String
}

struct ApplyPatchInput: Codable {
    let patch: String
}

struct ApplyPatchOutput: Codable {
    let success: Bool
    let paths: [String]
}

struct ListDirectoryInput: Codable {
    let path: String?
}

struct ListDirectoryOutput: Codable {
    let entries: [DirectoryEntry]
}

struct DirectoryEntry: Codable {
    let name: String
    let path: String
    let isDirectory: Bool

    enum CodingKeys: String, CodingKey {
        case name, path
        case isDirectory = "is_directory"
    }
}
