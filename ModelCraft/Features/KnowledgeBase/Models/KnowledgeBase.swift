//
//  KnowledgeBase.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 31/3/2024.
//
import Foundation
import SwiftData

import SVDB

enum IndexStatus: Int, Codable {
    case unindexed, indexing, indexed
}

@Model
class KnowledgeBase {
    @Attribute(.unique) let id = UUID()
    let createdAt: Date = Date.now
    var icon: String = "book"
    var title: String
    var files: Set<LocalFileURL> {
        didSet {
            embed()
        }
    }
    var indexStatus: IndexStatus
    
    init(title: String = "", files: Set<URL> = [],
         indexStatus: IndexStatus = .unindexed) {
        self.title = title
        self.files = files
        self.indexStatus = indexStatus
    }
}

extension KnowledgeBase {
    
    var orderedFiles: [LocalFileURL] {
        files.sorted(using: KeyPathComparator(\.lastPathComponent, order: .forward))
    }
    
    var collectionName: String {
        "knowledgeBase:\(id)"
    }
    
    func search(_ text: String) -> String {
        if indexStatus == .unindexed {
            Task.detached {
                self.embed()
            }
        }
        let retriever = Retriever(collectionName)
        let results = retriever.query(text)
        return results.map{ $0.text }.joined(separator: " ")
    }
    
    func embed() {
        indexStatus = .indexing
        SVDB.shared.releaseCollection(collectionName)
        embedFromFiles(orderedFiles)
        indexStatus = .indexed
    }
    
    func embedFromFiles(_ urls: [LocalFileURL]) {
        let retriever = Retriever(collectionName)
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
                    embedFromFiles(files)
                    continue
                }
                let document = try url.readContent()
                url.stopAccessingSecurityScopedResource()
                retriever.addDocuments(TextSplitter().createDocuments(document))
            }
        } catch {
            print("embedFromFiles error, \(error.localizedDescription)")
        }
    }
    
    func clear() {
        try? SVDB.shared.collection(collectionName).clear()
        SVDB.shared.releaseCollection(collectionName)
    }
}
