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
        writeFile,
        editFile,
        listDirectory
    ]
    
    static func writeFile(_ path: String, content: String) throws {
        try Task.checkCancellation()
        let url = fileURL(for: path)
        try ensureWritable(url)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let data = content.data(using: .utf8)!
        try data.write(to: url, options: .atomic)
        try Task.checkCancellation()
    }
    
    static func readFile(_ path: String) throws -> String {
        try Task.checkCancellation()
        let url = fileURL(for: path)
        let data = try Data(contentsOf: url)
        try Task.checkCancellation()
        return String(decoding: data, as: UTF8.self)
    }

    static func editFile(_ path: String, oldText: String, newText: String) throws -> Int {
        try Task.checkCancellation()
        guard !oldText.isEmpty else {
            throw FileToolError.emptyOldText
        }
        let content = try readFile(path)
        let matchCount = content.components(separatedBy: oldText).count - 1
        guard matchCount == 1 else {
            throw FileToolError.expectedOneMatch(actual: matchCount)
        }
        try writeFile(path, content: content.replacingOccurrences(of: oldText, with: newText))
        return matchCount
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
                isDirectory: try itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
    ){ input in
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
        return ReadFileOutput(content: lines[startIndex..<endIndex].joined(separator: "\n"))
    }
    
    static let writeFile = Tool<WriteFileInput, WriteFileOutput>(
        name: ToolNames.writeFile,
        description: "Write complete text content to a file in the current project's working folder. Creates missing parent directories and the file when needed; replaces the entire existing file rather than appending or patching it. Project reference files are read-only.",
        parameters: [
            .required("path", type: .string, description: "The absolute path, or a path relative to the current project's working folder (Documents when no working folder is configured). An existing file at this path will be overwritten unless it is a read-only project reference."),
            .required("content", type: .string, description: "The complete text that the file must contain after the write.")
        ]
    ) { input in
        try FileTool.writeFile(input.path, content: input.content)
        return WriteFileOutput(success: true, path: input.path)
    }

    static let editFile = Tool<EditFileInput, EditFileOutput>(
        name: ToolNames.editFile,
        description: "Patch an existing text file in the current project's working folder by replacing exactly one unique occurrence of literal text. Project reference files are read-only. The call fails without changing the file when the old text is absent or appears more than once.",
        parameters: [
            .required("path", type: .string, description: "The absolute path, or a path relative to the current project's working folder (Documents when no working folder is configured), of the existing text file to patch."),
            .required("old_text", type: .string, description: "The exact text to replace. It must occur exactly once."),
            .required("new_text", type: .string, description: "The complete replacement for old_text; use an empty string to delete that occurrence.")
        ]
    ) { input in
        let replacements = try FileTool.editFile(
            input.path,
            oldText: input.oldText,
            newText: input.newText)
        return EditFileOutput(success: true, path: input.path, replacements: replacements)
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

enum FileToolError: LocalizedError {
    case outsideWorkingDirectory
    case readOnlyReference
    case emptyOldText
    case expectedOneMatch(actual: Int)
    case invalidLineRange
    case lineOutOfRange

    var errorDescription: String? {
        switch self {
        case .outsideWorkingDirectory:
            "Files outside the project's working folder cannot be changed."
        case .readOnlyReference:
            "Project reference files are read-only."
        case .emptyOldText:
            "old_text must not be empty."
        case .expectedOneMatch(let actual):
            "Expected old_text to match exactly once, but found \(actual) matches."
        case .invalidLineRange:
            "start_line and line_count must be greater than zero."
        case .lineOutOfRange:
            "start_line is beyond the end of the file."
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

struct WriteFileInput: Codable {
    let path: String
    let content: String
}

struct WriteFileOutput: Codable {
    let success: Bool
    let path: String
}

struct EditFileInput: Codable {
    let path: String
    let oldText: String
    let newText: String

    enum CodingKeys: String, CodingKey {
        case path
        case oldText = "old_text"
        case newText = "new_text"
    }
}

struct EditFileOutput: Codable {
    let success: Bool
    let path: String
    let replacements: Int
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
