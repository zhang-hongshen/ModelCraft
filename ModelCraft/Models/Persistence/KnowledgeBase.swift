//
//  KnowledgeBase.swift
//  ModelCraft
//
//  Created by Hongshen on 31/3/2024.
//
import Foundation
import SwiftData

import SVDB

@Model
class KnowledgeBase {
    @Attribute(.unique) var id = UUID()
    var createdAt: Date = Date.now
    var icon: String = "book"
    var title: String
    var files: [LocalFileURL] {
        didSet {
            let newFiles = files.filter { !oldValue.contains($0) }
            if newFiles.isEmpty {
                return
            }
            createIndex(newFiles)
        }
    }
    
    init(title: String = "", files: [URL] = []) {
        self.title = title
        self.files = files
    }
}

extension KnowledgeBase {
    
    private var dbPath: String {
        let folder = URL.documentsDirectory
        return folder.appendingPathComponent("\(id.uuidString).fts5").path
    }
        
    func search(query: String, numOfResults: Int = 10) async -> [String] {
        return KnowledgeIndexer(dbPath: dbPath).search(query: query, numOfResults: numOfResults)
    }
    
    func createIndex(_ urls: [LocalFileURL]) {
        let engine = KnowledgeIndexer(dbPath: dbPath)
        let fileManager = FileManager.default
        
        Task {
            var docs: [String: String] = [:]
            
            await withTaskGroup(of: (String, String)?.self) { group in
                for url in urls {
                    group.addTask {
                        guard url.startAccessingSecurityScopedResource(),
                              fileManager.fileExists(at: url) else { return nil }
                        
                        defer { url.stopAccessingSecurityScopedResource() }
                        
                        if let doc = try? await url.readContent() {
                            return (url.path(), doc)
                        }
                        return nil
                    }
                }
                
                for await result in group {
                    if let (path, content) = result {
                        docs[path] = content
                    }
                }
            }
            
            if !docs.isEmpty {
                engine.createIndex(docs: docs)
            }
        }
    }
    
    func clear() {
        let engine = KnowledgeIndexer(dbPath: dbPath)
        files.forEach { url in
            engine.removeIndex(path: url.path())
        }
    }
    
    
    func removeFiles<T>(_ urls: T) where T: Swift.Collection, T.Element == LocalFileURL {
        let engine = KnowledgeIndexer(dbPath: dbPath)
        self.files.removeAll { urls.contains($0) }
        engine.removeIndex(paths: urls.compactMap{ $0.path() })
    }
}


import SQLite3
class KnowledgeIndexer {
    private var db: OpaquePointer?
    
    init(dbPath: String) {
        sqlite3_open(dbPath, &db)
        let setup = "CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5(file_path, content, tokenize='porter');"
        sqlite3_exec(db, setup, nil, nil, nil)
    }
    
    func createIndex(path: String, content: String) {
        let sql = "INSERT INTO docs (file_path, content) VALUES (?, ?);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (content as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }
    
    
    func createIndex(docs: [String: String]) {
        let sql = "INSERT INTO docs (file_path, content) VALUES (?, ?);"
        var stmt: OpaquePointer?

        sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
        
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            for (path, content) in docs {
                sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (content as NSString).utf8String, -1, nil)
                
                sqlite3_step(stmt)
                
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
            }
        }
        
        sqlite3_finalize(stmt)
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }
    
    func removeIndex(path: String) {
        let sql = "DELETE FROM docs WHERE file_path = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }
    
    func removeIndex(paths: [String]) {
        guard !paths.isEmpty else { return }
        
        sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
        
        let sql = "DELETE FROM docs WHERE file_path = ?;"
        var stmt: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            for path in paths {
                sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
                sqlite3_reset(stmt)
            }
        }
        sqlite3_finalize(stmt)
        
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        
        sqlite3_exec(db, "INSERT INTO docs(docs) VALUES('optimize');", nil, nil, nil)
    }
    
    func search(query: String, numOfResults: Int = 10) -> [String] {
        let sql = "SELECT file_path, content FROM docs WHERE content MATCH ? LIMIT ?;"
        var stmt: OpaquePointer?
        var results: [String] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (query as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(numOfResults))
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                let path = String(cString: sqlite3_column_text(stmt, 0))
                let content = String(cString: sqlite3_column_text(stmt, 1))
                results.append("File: \(path)\nSnippet: \(content.prefix(100))...")
            }
        }
        sqlite3_finalize(stmt)
        return results
    }
}
