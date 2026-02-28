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
            let addedFiles = files.filter { !oldValue.contains($0) }
            if addedFiles.isEmpty {
                return
            }
            indexStatus = .indexing
            doCreateEmedding(addedFiles)
            indexStatus = .indexed
        }
    }
    var indexStatus: IndexStatus
    
    init(title: String = "", files: [URL] = [],
         indexStatus: IndexStatus = .unindexed) {
        self.title = title
        self.files = files
        self.indexStatus = indexStatus
    }
}

extension KnowledgeBase {
    
    var collectionName: String {
        "knowledgeBase:\(id)"
    }
    
    func search(_ text: String, numOfResults: Int? = nil) async -> [String] {
        if indexStatus == .unindexed {
            Task.detached {
                self.createEmedding()
            }
        }
        return await CollectionManager(collectionName).query(text, numOfResults: numOfResults ?? 10).map{ $0.text }
    }
    
    func createEmedding() {
        indexStatus = .indexing
        SVDB.shared.releaseCollection(collectionName)
        doCreateEmedding(files)
        indexStatus = .indexed
    }
    
    func doCreateEmedding(_ urls: [LocalFileURL]) {
        let collectionManager = CollectionManager(collectionName)
        let fileManager = FileManager.default
        do  {
            for url in urls {
                if !url.startAccessingSecurityScopedResource()
                    || !fileManager.fileExists(at: url) {
                    continue
                }
                if url.hasDirectoryPath {
                    let files = try fileManager
                        .contentsOfDirectory(at: url,
                                             includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles])
                    doCreateEmedding(files)
                    continue
                }
                Task {
                    let doc = try await url.readContent()
                    url.stopAccessingSecurityScopedResource()
                    collectionManager.addDocument(doc)
                }
            }
        } catch {
            print("embedFromFiles error, \(error.localizedDescription)")
        }
    }
    
    func clear() {
        try? SVDB.shared.collection(collectionName).clear()
        SVDB.shared.releaseCollection(collectionName)
    }
    
    
    func removeFiles<T>(_ urls: T) where T: Swift.Collection, T.Element == LocalFileURL {
        self.files.removeAll { urls.contains($0) }
    }
}

enum IndexStatus: Int, Codable {
    case unindexed, indexing, indexed
}
