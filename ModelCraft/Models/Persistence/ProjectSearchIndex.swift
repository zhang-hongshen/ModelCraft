//
//  ProjectSearchIndex.swift
//  ModelCraft
//

import AppKit
import Foundation
import NaturalLanguage
import PDFKit
import SQLite3

enum ProjectSearchPurpose: String, Codable {
    case automatic
    case understand
    case locate
    case edit
}

struct ProjectSearchResult: Codable {
    let path: String
    let source: String
    let kind: String
    let location: String
    let startLine: Int?
    let endLine: Int?
    let snippet: String
    let matchReason: String

    enum CodingKeys: String, CodingKey {
        case path, source, kind, location, snippet
        case startLine = "start_line"
        case endLine = "end_line"
        case matchReason = "match_reason"
    }
}

final class ProjectSearchIndex {
    private enum Source: String {
        case workspace
        case reference
    }

    private enum Kind: String {
        case code
        case document
        case structuredData = "structured_data"
        case transcript
    }

    private struct FileCandidate {
        let url: URL
        let displayPath: String
        let source: Source
        let kind: Kind
        let fingerprint: String
    }

    private struct Chunk {
        let location: String
        let startLine: Int?
        let endLine: Int?
        let content: String
    }

    private static let schemaVersion: Int32 = 5
    private static let maximumTextFileSize = 5 * 1_024 * 1_024
    private static let ignoredDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", ".next", ".cache",
        "build", "Build", "DerivedData", "node_modules", "Pods",
        "Carthage", "vendor", "dist", "coverage"
    ]
    private static let searchableHiddenDirectories: Set<String> = [".github", ".vscode"]
    private static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "cxx", "hpp",
        "py", "pyi", "js", "jsx", "ts", "tsx", "java", "kt", "kts",
        "rs", "go", "rb", "php", "cs", "fs", "fsx", "scala", "sh",
        "bash", "zsh", "fish", "sql", "css", "scss", "sass", "less",
        "vue", "svelte", "dart", "lua", "r", "ex", "exs", "erl", "hrl"
    ]
    private static let documentExtensions: Set<String> = [
        "md", "markdown", "mdown", "txt", "text", "rst", "adoc",
        "pdf", "rtf", "rtfd", "html", "htm", "doc", "docx", "odt"
    ]
    private static let structuredExtensions: Set<String> = [
        "json", "jsonc", "yaml", "yml", "toml", "xml", "plist",
        "csv", "tsv", "ini", "conf", "config", "xcconfig", "pbxproj"
    ]
    private static let transcriptExtensions: Set<String> = [
        "mp3", "wav", "m4a", "aac", "flac", "aiff", "aif", "caf"
    ]

    private var db: OpaquePointer?

    init(dbPath: String) {
        sqlite3_open(dbPath, &db)
        prepareSchema()
    }

    deinit {
        sqlite3_close(db)
    }

    func search(
        query: String,
        purpose: ProjectSearchPurpose,
        workingDirectory: URL?,
        resources: [URL],
        limit: Int
    ) async -> [ProjectSearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, limit > 0 else { return [] }

        let roots = ([workingDirectory].compactMap { $0 } + resources)
            .map(\.standardizedFileURL)
        let accessedRoots = roots.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessedRoots.forEach { $0.stopAccessingSecurityScopedResource() } }

        let files = collectFiles(
            workingDirectory: workingDirectory?.standardizedFileURL,
            resources: resources.map(\.standardizedFileURL))
        await synchronize(files)
        guard !Task.isCancelled else { return [] }

        let resolvedPurpose = resolvePurpose(purpose, query: trimmedQuery)
        let candidateLimit = max(limit * 8, 40)
        var candidates = searchPaths(query: trimmedQuery, purpose: resolvedPurpose)
        candidates += searchSymbols(
            query: trimmedQuery,
            purpose: resolvedPurpose,
            limit: candidateLimit)
        candidates += searchCallGraph(
            query: trimmedQuery,
            purpose: resolvedPurpose,
            limit: candidateLimit)
        candidates += searchChunks(
            query: trimmedQuery,
            purpose: resolvedPurpose,
            limit: candidateLimit)
        if resolvedPurpose == .understand || resolvedPurpose == .automatic {
            candidates += semanticMatches(query: trimmedQuery, limit: candidateLimit)
        }
        return ProjectSearchReranker.rerank(
            query: trimmedQuery,
            purpose: resolvedPurpose,
            candidates: candidates,
            limit: limit)
    }

    func remove(paths: [String]) {
        guard !paths.isEmpty else { return }
        execute("BEGIN IMMEDIATE TRANSACTION")
        for path in paths {
            remove(path: path)
        }
        execute("COMMIT")
    }

    private func prepareSchema() {
        guard scalarInt("PRAGMA user_version") == Self.schemaVersion else {
            execute("DROP TABLE IF EXISTS docs")
            execute("DROP TABLE IF EXISTS chunks")
            execute("DROP TABLE IF EXISTS symbols")
            execute("DROP TABLE IF EXISTS call_edges")
            execute("DROP TABLE IF EXISTS chunk_embeddings")
            execute("DROP TABLE IF EXISTS file_catalog")
            createSchema()
            execute("PRAGMA user_version = \(Self.schemaVersion)")
            return
        }
        createSchema()
    }

    private func createSchema() {
        execute("""
            CREATE TABLE IF NOT EXISTS file_catalog (
                path TEXT PRIMARY KEY,
                display_path TEXT NOT NULL,
                source TEXT NOT NULL,
                kind TEXT NOT NULL,
                fingerprint TEXT NOT NULL
            )
            """)
        execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(
                path UNINDEXED,
                display_path UNINDEXED,
                source UNINDEXED,
                kind UNINDEXED,
                location UNINDEXED,
                start_line UNINDEXED,
                end_line UNINDEXED,
                content UNINDEXED,
                search_text,
                tokenize='unicode61 remove_diacritics 2'
            )
            """)
        execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS symbols USING fts5(
                path UNINDEXED,
                display_path UNINDEXED,
                source UNINDEXED,
                file_kind UNINDEXED,
                name UNINDEXED,
                qualified_name UNINDEXED,
                role UNINDEXED,
                symbol_kind UNINDEXED,
                container UNINDEXED,
                line UNINDEXED,
                end_line UNINDEXED,
                signature UNINDEXED,
                search_text,
                tokenize='unicode61 remove_diacritics 2'
            )
            """)
        execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS call_edges USING fts5(
                path UNINDEXED,
                display_path UNINDEXED,
                source UNINDEXED,
                caller UNINDEXED,
                callee UNINDEXED,
                line UNINDEXED,
                signature UNINDEXED,
                search_text,
                tokenize='unicode61 remove_diacritics 2'
            )
            """)
        execute("""
            CREATE TABLE IF NOT EXISTS chunk_embeddings (
                chunk_rowid INTEGER PRIMARY KEY,
                vector BLOB NOT NULL
            )
            """)
    }

    private func collectFiles(workingDirectory: URL?, resources: [URL]) -> [FileCandidate] {
        var files: [String: FileCandidate] = [:]
        if let workingDirectory {
            for url in recursiveFiles(at: workingDirectory) {
                guard let candidate = candidate(
                    for: url,
                    displayPath: relativePath(of: url, under: workingDirectory),
                    source: .workspace)
                else { continue }
                files[candidate.url.path] = candidate
            }
        }

        for resource in resources {
            let isDirectory = (try? resource.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let urls = isDirectory ? recursiveFiles(at: resource) : [resource]
            for url in urls {
                guard files[url.path] == nil,
                      let candidate = candidate(
                        for: url,
                        displayPath: isDirectory
                            ? relativePath(of: url, under: resource)
                            : url.lastPathComponent,
                        source: .reference)
                else { continue }
                files[candidate.url.path] = candidate
            }
        }
        return Array(files.values)
    }

    private func recursiveFiles(at root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                .fileSizeKey, .contentModificationDateKey
            ],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard !Task.isCancelled else { break }
            let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey
            ])
            if values?.isDirectory == true {
                if Self.ignoredDirectories.contains(url.lastPathComponent)
                    || (values?.isHidden == true
                        && !Self.searchableHiddenDirectories.contains(url.lastPathComponent)) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            urls.append(url.standardizedFileURL)
        }
        return urls
    }

    private func candidate(
        for url: URL,
        displayPath: String,
        source: Source
    ) -> FileCandidate? {
        guard let kind = kind(for: url) else { return nil }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        if kind != .transcript, size > Self.maximumTextFileSize { return nil }
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return FileCandidate(
            url: url,
            displayPath: displayPath,
            source: source,
            kind: kind,
            fingerprint: "\(size):\(modified)")
    }

    private func kind(for url: URL) -> Kind? {
        let ext = url.pathExtension.lowercased()
        if Self.codeExtensions.contains(ext) { return .code }
        if Self.documentExtensions.contains(ext) { return .document }
        if Self.structuredExtensions.contains(ext) { return .structuredData }
        if Self.transcriptExtensions.contains(ext) { return .transcript }
        return nil
    }

    private func relativePath(of url: URL, under root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.starts(with: rootComponents) else { return url.lastPathComponent }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func synchronize(_ candidates: [FileCandidate]) async {
        let known = catalogFingerprints()
        let currentPaths = Set(candidates.map(\.url.path))

        execute("BEGIN IMMEDIATE TRANSACTION")
        for path in known.keys where !currentPaths.contains(path) {
            remove(path: path)
        }
        execute("COMMIT")

        for candidate in candidates where known[candidate.url.path] != candidate.fingerprint {
            guard !Task.isCancelled else { return }
            await index(candidate)
        }
    }

    private func index(_ file: FileCandidate) async {
        guard let content = await content(of: file), !content.isEmpty else {
            execute("BEGIN IMMEDIATE TRANSACTION")
            remove(path: file.url.path)
            replaceCatalogEntry(file)
            execute("COMMIT")
            return
        }

        execute("BEGIN IMMEDIATE TRANSACTION")
        remove(path: file.url.path)
        replaceCatalogEntry(file)
        for chunk in chunks(for: content, kind: file.kind) {
            insertChunk(chunk, file: file)
        }
        if file.kind == .code,
           let structure = CodeStructureParser.parse(
            content,
            fileExtension: file.url.pathExtension.lowercased()) {
            insert(structure, file: file)
        } else if file.kind == .structuredData {
            insertStructuredSymbols(from: content, file: file)
        }
        execute("COMMIT")
    }

    private func content(of file: FileCandidate) async -> String? {
        switch file.kind {
        case .transcript:
            guard file.source == .reference else { return nil }
            return try? await file.url.readContent()
        case .document:
            let ext = file.url.pathExtension.lowercased()
            if ext == "pdf" {
                return pdfContent(file.url)
            }
            if ["rtf", "rtfd", "html", "htm", "doc", "docx", "odt"].contains(ext),
               let attributed = try? NSAttributedString(
                url: file.url,
                options: [:],
                documentAttributes: nil) {
                return attributed.string
            }
            return readUTF8(file.url)
        case .code, .structuredData:
            return readUTF8(file.url)
        }
    }

    private func readUTF8(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
    }

    private func pdfContent(_ url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        return (0..<document.pageCount).compactMap { index in
            guard let content = document.page(at: index)?.string, !content.isEmpty else { return nil }
            return "# Page \(index + 1)\n\(content)"
        }.joined(separator: "\n\n")
    }

    private func chunks(for content: String, kind: Kind) -> [Chunk] {
        if kind == .document || kind == .transcript {
            return documentChunks(for: content)
        }
        let lines = content.components(separatedBy: .newlines)
        let maximumLines = 80
        let overlap = 10
        var chunks: [Chunk] = []
        var start = 0

        while start < lines.count {
            let end = min(start + maximumLines, lines.count)
            let slice = lines[start..<end]
            let text = slice.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let startLine = start + 1
                let endLine = end
                chunks.append(Chunk(
                    location: "lines \(startLine)-\(endLine)",
                    startLine: startLine,
                    endLine: endLine,
                    content: text))
            }
            if end == lines.count { break }
            start = max(start + 1, end - overlap)
        }
        return chunks
    }

    private func documentChunks(for content: String) -> [Chunk] {
        let lines = content.components(separatedBy: .newlines)
        var chunks: [Chunk] = []
        var buffer: [String] = []
        var startLine = 1
        var heading: String?

        func appendChunk(endingAt endLine: Int) {
            let text = buffer.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            chunks.append(Chunk(
                location: heading ?? "lines \(startLine)-\(endLine)",
                startLine: startLine,
                endLine: endLine,
                content: text))
        }

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isHeading = trimmed.hasPrefix("#")
            let bufferedCharacters = buffer.reduce(0) { $0 + $1.count + 1 }
            if !buffer.isEmpty && (isHeading || (trimmed.isEmpty && bufferedCharacters >= 1_600)) {
                appendChunk(endingAt: lineNumber - 1)
                buffer.removeAll(keepingCapacity: true)
                startLine = lineNumber
            }
            if isHeading {
                heading = trimmed
            }
            buffer.append(line)
        }
        appendChunk(endingAt: lines.count)
        return chunks
    }

    private func insertChunk(_ chunk: Chunk, file: FileCandidate) {
        let sql = """
            INSERT INTO chunks (
                path, display_path, source, kind, location,
                start_line, end_line, content, search_text
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(file.url.path, at: 1, in: statement)
        bind(file.displayPath, at: 2, in: statement)
        bind(file.source.rawValue, at: 3, in: statement)
        bind(file.kind.rawValue, at: 4, in: statement)
        bind(chunk.location, at: 5, in: statement)
        bind(chunk.startLine, at: 6, in: statement)
        bind(chunk.endLine, at: 7, in: statement)
        bind(chunk.content, at: 8, in: statement)
        bind(searchableText("\(file.displayPath) \(chunk.content)"), at: 9, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { return }

        guard (file.kind == .document || file.kind == .transcript),
              let embedding = NLEmbedding.sentenceEmbedding(for: chunk.content)
        else { return }
        insertEmbedding(embedding, rowID: sqlite3_last_insert_rowid(db))
    }

    private func insertStructuredSymbols(from content: String, file: FileCandidate) {
        guard let pattern = try? NSRegularExpression(
            pattern: #"^\s*[\"']?([A-Za-z_][A-Za-z0-9_.-]*)[\"']?\s*([:=])"#)
        else { return }
        let lines = content.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = pattern.firstMatch(in: line, range: range),
                  let nameRange = Range(match.range(at: 1), in: line)
            else { continue }
            let name = String(line[nameRange])
            insertSymbol(CodeSymbolOccurrence(
                name: name,
                qualifiedName: name,
                role: .definition,
                kind: "key",
                container: nil,
                startLine: index + 1,
                endLine: index + 1,
                signature: String(line.trimmingCharacters(in: .whitespaces).prefix(300))),
                file: file)
        }
    }

    private func insert(_ structure: CodeStructure, file: FileCandidate) {
        for symbol in structure.symbols {
            insertSymbol(symbol, file: file)
        }
        for call in structure.calls {
            insertCall(call, file: file)
        }
    }

    private func insertSymbol(
        _ symbol: CodeSymbolOccurrence,
        file: FileCandidate
    ) {
        let sql = """
            INSERT INTO symbols (
                path, display_path, source, file_kind,
                name, qualified_name, role, symbol_kind, container,
                line, end_line, signature, search_text
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(file.url.path, at: 1, in: statement)
        bind(file.displayPath, at: 2, in: statement)
        bind(file.source.rawValue, at: 3, in: statement)
        bind(file.kind.rawValue, at: 4, in: statement)
        bind(symbol.name, at: 5, in: statement)
        bind(symbol.qualifiedName, at: 6, in: statement)
        bind(symbol.role.rawValue, at: 7, in: statement)
        bind(symbol.kind, at: 8, in: statement)
        bind(symbol.container, at: 9, in: statement)
        bind(symbol.startLine, at: 10, in: statement)
        bind(symbol.endLine, at: 11, in: statement)
        bind(symbol.signature, at: 12, in: statement)
        bind(searchableText("\(symbol.name) \(symbol.qualifiedName) \(symbol.signature) \(file.displayPath)"), at: 13, in: statement)
        sqlite3_step(statement)
    }

    private func insertCall(_ call: CodeCallEdge, file: FileCandidate) {
        let sql = """
            INSERT INTO call_edges (
                path, display_path, source, caller, callee, line, signature, search_text
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(file.url.path, at: 1, in: statement)
        bind(file.displayPath, at: 2, in: statement)
        bind(file.source.rawValue, at: 3, in: statement)
        bind(call.caller, at: 4, in: statement)
        bind(call.callee, at: 5, in: statement)
        bind(call.line, at: 6, in: statement)
        bind(call.signature, at: 7, in: statement)
        bind(searchableText("\(call.caller) \(call.callee) \(call.signature) \(file.displayPath)"), at: 8, in: statement)
        sqlite3_step(statement)
    }

    private func insertEmbedding(_ values: [Double], rowID: Int64) {
        let floats = values.map(Float.init)
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO chunk_embeddings (chunk_rowid, vector) VALUES (?, ?)",
            -1,
            &statement,
            nil) == SQLITE_OK
        else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, rowID)
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
        sqlite3_step(statement)
    }

    private func searchPaths(query: String, purpose: ProjectSearchPurpose) -> [ProjectSearchCandidate] {
        let tokens = searchTokens(query)
        guard !tokens.isEmpty else { return [] }
        let rows = catalogRows()
        return rows.compactMap { path, displayPath, source, kind in
            let haystack = displayPath.lowercased()
            let matched = tokens.filter { haystack.contains($0.lowercased()) }
            guard !matched.isEmpty else { return nil }
            let score = (purpose == .locate || purpose == .edit ? 34.0 : 18.0)
                + Double(matched.count * 3)
            return ProjectSearchCandidate(
                result: ProjectSearchResult(
                    path: path,
                    source: source,
                    kind: kind,
                    location: "file path",
                    startLine: nil,
                    endLine: nil,
                    snippet: displayPath,
                    matchReason: "path"),
                retrievalScore: score)
        }
    }

    private func searchSymbols(
        query: String,
        purpose: ProjectSearchPurpose,
        limit: Int
    ) -> [ProjectSearchCandidate] {
        guard let expression = matchExpression(query) else { return [] }
        let sql = """
            SELECT path, display_path, source, file_kind,
                   name, qualified_name, role, symbol_kind, container,
                   line, end_line, signature, bm25(symbols)
            FROM symbols WHERE search_text MATCH ? ORDER BY bm25(symbols) LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(expression, at: 1, in: statement)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var results: [ProjectSearchCandidate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let line = Int(sqlite3_column_int(statement, 9))
            let endLine = Int(sqlite3_column_int(statement, 10))
            let role = text(statement, 6)
            let rank = abs(sqlite3_column_double(statement, 12))
            results.append(ProjectSearchCandidate(
                result: ProjectSearchResult(
                    path: text(statement, 0),
                    source: text(statement, 2),
                    kind: text(statement, 3),
                    location: "\(role) \(text(statement, 7)) \(text(statement, 5)) at line \(line)",
                    startLine: line,
                    endLine: endLine,
                    snippet: text(statement, 11),
                    matchReason: role == CodeSymbolOccurrence.Role.definition.rawValue
                        ? "symbol_definition" : "symbol_reference"),
                retrievalScore: (purpose == .locate || purpose == .edit ? 50 : 28)
                    + (role == CodeSymbolOccurrence.Role.definition.rawValue ? 12 : 4)
                    + 1 / (1 + rank)))
        }
        return results
    }

    private func searchCallGraph(
        query: String,
        purpose: ProjectSearchPurpose,
        limit: Int
    ) -> [ProjectSearchCandidate] {
        guard let expression = matchExpression(query) else { return [] }
        let sql = """
            SELECT path, source, caller, callee, line, signature, bm25(call_edges)
            FROM call_edges WHERE search_text MATCH ? ORDER BY bm25(call_edges) LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(expression, at: 1, in: statement)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var results: [ProjectSearchCandidate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let line = Int(sqlite3_column_int(statement, 4))
            let rank = abs(sqlite3_column_double(statement, 6))
            let caller = text(statement, 2)
            let callee = text(statement, 3)
            results.append(ProjectSearchCandidate(
                result: ProjectSearchResult(
                    path: text(statement, 0),
                    source: text(statement, 1),
                    kind: Kind.code.rawValue,
                    location: "call \(caller) → \(callee) at line \(line)",
                    startLine: line,
                    endLine: line,
                    snippet: text(statement, 5),
                    matchReason: "call_graph"),
                retrievalScore: (purpose == .edit || purpose == .locate ? 48 : 34) + 1 / (1 + rank)))
        }
        return results
    }

    private func searchChunks(
        query: String,
        purpose: ProjectSearchPurpose,
        limit: Int
    ) -> [ProjectSearchCandidate] {
        guard let expression = matchExpression(query) else { return [] }
        let sql = """
            SELECT path, source, kind, location, start_line, end_line, content, bm25(chunks)
            FROM chunks WHERE search_text MATCH ? ORDER BY bm25(chunks) LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(expression, at: 1, in: statement)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var results: [ProjectSearchCandidate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let kind = text(statement, 2)
            let rank = abs(sqlite3_column_double(statement, 7))
            let documentBoost = purpose == .understand && kind != Kind.code.rawValue ? 34.0 : 16.0
            results.append(ProjectSearchCandidate(
                result: ProjectSearchResult(
                    path: text(statement, 0),
                    source: text(statement, 1),
                    kind: kind,
                    location: text(statement, 3),
                    startLine: optionalInt(statement, 4),
                    endLine: optionalInt(statement, 5),
                    snippet: String(text(statement, 6).prefix(1_800)),
                    matchReason: "keyword"),
                retrievalScore: documentBoost + 1 / (1 + rank)))
        }
        return results
    }

    private func semanticMatches(query: String, limit: Int) -> [ProjectSearchCandidate] {
        guard let queryVector = NLEmbedding.sentenceEmbedding(for: query) else { return [] }
        let floats = queryVector.map(Float.init)
        let sql = """
            SELECT chunks.path, chunks.source, chunks.kind, chunks.location,
                   chunks.start_line, chunks.end_line, chunks.content,
                   chunk_embeddings.vector
            FROM chunk_embeddings
            JOIN chunks ON chunks.rowid = chunk_embeddings.chunk_rowid
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var results: [ProjectSearchCandidate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard !Task.isCancelled,
                  let vector = floatVector(statement, column: 7),
                  vector.count == floats.count
            else { continue }
            let similarity = cosine(floats, vector)
            guard similarity >= 0.42 else { continue }
            results.append(ProjectSearchCandidate(
                result: ProjectSearchResult(
                    path: text(statement, 0),
                    source: text(statement, 1),
                    kind: text(statement, 2),
                    location: text(statement, 3),
                    startLine: optionalInt(statement, 4),
                    endLine: optionalInt(statement, 5),
                    snippet: String(text(statement, 6).prefix(1_800)),
                    matchReason: "semantic"),
                retrievalScore: 20 + Double(similarity * 20)))
        }
        return results.sorted { $0.retrievalScore > $1.retrievalScore }.prefix(limit).map { $0 }
    }

    private func resolvePurpose(_ purpose: ProjectSearchPurpose, query: String) -> ProjectSearchPurpose {
        guard purpose == .automatic else { return purpose }
        let lowercased = query.lowercased()
        let editWords = ["修改", "修复", "实现", "重构", "删除", "rename", "edit", "fix", "implement", "refactor"]
        if editWords.contains(where: lowercased.contains) { return .edit }
        let locateWords = ["在哪里", "哪个文件", "定义", "声明", "where is", "find", "definition", "symbol"]
        if locateWords.contains(where: lowercased.contains) { return .locate }
        return .understand
    }

    private func replaceCatalogEntry(_ file: FileCandidate) {
        let sql = """
            INSERT OR REPLACE INTO file_catalog
            (path, display_path, source, kind, fingerprint) VALUES (?, ?, ?, ?, ?)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(file.url.path, at: 1, in: statement)
        bind(file.displayPath, at: 2, in: statement)
        bind(file.source.rawValue, at: 3, in: statement)
        bind(file.kind.rawValue, at: 4, in: statement)
        bind(file.fingerprint, at: 5, in: statement)
        sqlite3_step(statement)
    }

    private func remove(path: String) {
        execute("DELETE FROM chunk_embeddings WHERE chunk_rowid IN (SELECT rowid FROM chunks WHERE path = ?)", values: [path])
        execute("DELETE FROM chunks WHERE path = ?", values: [path])
        execute("DELETE FROM symbols WHERE path = ?", values: [path])
        execute("DELETE FROM call_edges WHERE path = ?", values: [path])
        execute("DELETE FROM file_catalog WHERE path = ?", values: [path])
    }

    private func catalogFingerprints() -> [String: String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT path, fingerprint FROM file_catalog", -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            result[text(statement, 0)] = text(statement, 1)
        }
        return result
    }

    private func catalogRows() -> [(String, String, String, String)] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT path, display_path, source, kind FROM file_catalog", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [(String, String, String, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((text(statement, 0), text(statement, 1), text(statement, 2), text(statement, 3)))
        }
        return result
    }

    private func searchableText(_ text: String) -> String {
        "\(text) \(splitIdentifier(text)) \(cjkNGrams(text))"
    }

    private func splitIdentifier(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(
                of: "([a-z0-9])([A-Z])",
                with: "$1 $2",
                options: .regularExpression)
    }

    private func cjkNGrams(_ text: String) -> String {
        let runs = text.split { character in
            !character.unicodeScalars.allSatisfy { scalar in
                (0x3400...0x9FFF).contains(Int(scalar.value))
            }
        }
        return runs.flatMap { run -> [String] in
            let characters = Array(run)
            guard characters.count > 1 else { return [String(run)] }
            return (0..<(characters.count - 1)).map {
                String(characters[$0...($0 + 1)])
            }
        }.joined(separator: " ")
    }

    private func searchTokens(_ query: String) -> [String] {
        let expanded = searchableText(query).lowercased()
        return Array(Set(expanded.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init)))
            .filter { !$0.isEmpty }
    }

    private func matchExpression(_ query: String) -> String? {
        let tokens = searchTokens(query)
        guard !tokens.isEmpty else { return nil }
        return tokens.prefix(24).map {
            "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\""
        }.joined(separator: " OR ")
    }

    private func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var dot: Float = 0
        var lhsLength: Float = 0
        var rhsLength: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsLength += lhs[index] * lhs[index]
            rhsLength += rhs[index] * rhs[index]
        }
        guard lhsLength > 0, rhsLength > 0 else { return 0 }
        return dot / (sqrt(lhsLength) * sqrt(rhsLength))
    }

    private func floatVector(_ statement: OpaquePointer?, column: Int32) -> [Float]? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column)) / MemoryLayout<Float>.size
        return Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: Float.self), count: count))
    }

    private var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, sqliteTransient)
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer?) {
        if let value {
            bind(value, at: index, in: statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ value: Int?, at index: Int32, in statement: OpaquePointer?) {
        if let value {
            sqlite3_bind_int(statement, index, Int32(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func optionalInt(_ statement: OpaquePointer?, _ column: Int32) -> Int? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(statement, column))
    }

    private func scalarInt(_ sql: String) -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
    }

    private func execute(_ sql: String, values: [String] = []) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            bind(value, at: Int32(offset + 1), in: statement)
        }
        sqlite3_step(statement)
    }
}
