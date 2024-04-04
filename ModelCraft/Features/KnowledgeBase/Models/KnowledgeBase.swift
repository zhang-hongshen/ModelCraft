//
//  KnowledgeBase.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 31/3/2024.
//
import Foundation
import SwiftData
import NaturalLanguage

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
    var files: Set<URL>
    var indexStatus: IndexStatus
    
    init(title: String = "", files: Set<URL> = [],
         indexStatus: IndexStatus = .unindexed) {
        self.title = title
        self.files = files
        self.indexStatus = indexStatus
    }
    
    var orderedFiles: [URL] {
        files.sorted(using: KeyPathComparator(\.lastPathComponent, order: .forward))
    }
}

extension KnowledgeBase {
    
    var collectionName: String {
        "knowledgeBase:\(id)"
    }
    
    func getVectorCollection() -> Collection {
        // collection只能创建collection
        do {
            return try SVDB.shared.collection(collectionName)
        } catch {
            debugPrint("error, \(error.localizedDescription)")
        }
        return SVDB.shared.getCollection(collectionName)!
    }
    
    func search(_ text: String) -> String {
        let collection = SVDB.shared.getCollection(collectionName)
        if indexStatus == .unindexed || collection == nil {
            index(orderedFiles)
        }
        guard let collection = SVDB.shared.getCollection(collectionName) else { return ""}
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return ""}
        guard let embed = NLEmbedding.sentenceEmbedding(for: language) else { return ""}
        guard let embedding = embed.vector(for: text) else { return ""}
        let results = collection.search(query: embedding)
        return results.map{ $0.text }.joined(separator: "\n")
    }
    
    func index(_ urls: [URL]) {
        let collection = getVectorCollection()
        let fileManager = FileManager.default
        indexStatus = .indexing
        do  {
            for url in urls {
                if url.hasDirectoryPath {
                    index(try fileManager
                        .contentsOfDirectory(at: url,
                                             includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles]))
                    continue
                }
                if !fileManager.fileExists(at: url) { continue }
                let document = try url.readContent()
                guard let language = NLLanguageRecognizer.dominantLanguage(for: document) else { continue }
                guard let embed = NLEmbedding.sentenceEmbedding(for: language) else { continue }
                document.split(separator: .newlines, chunkSize: 100).forEach { chunk in
                    guard let embedding = embed.vector(for: chunk) else { return }
                    collection.addDocument(id: id, text: chunk, embedding: embedding)
                }
            }
        } catch {
            print("index error, \(error.localizedDescription)")
        }
        indexStatus = .indexed
        
    }
}
