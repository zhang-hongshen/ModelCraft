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

@Model
class KnowledgeBase {
    @Attribute(.unique) let id = UUID()
    let createdAt: Date = Date.now
    var icon: String = "book"
    var title: String
    var files: Set<URL>
    
    init(title: String = "", files: Set<URL> = []) {
        self.title = title
        self.files = files
    }
    
    var orderedFiles: [URL] {
        files.sorted(using: KeyPathComparator(\.lastPathComponent, order: .forward))
    }
}

extension KnowledgeBase {
    
    func getVectorCollection() -> Collection {
        // collection只能创建collection
        do {
            return try SVDB.shared.collection("knowledgeBase:\(id)")
        } catch {
            debugPrint("error, \(error.localizedDescription)")
        }
        return SVDB.shared.getCollection("knowledgeBase:\(id)")!
    }
    
    func search(_ text: String) -> String {
        var res = ""
        do {
            try generateEmbedding(orderedFiles)
            guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return ""}
            guard let embed = NLEmbedding.sentenceEmbedding(for: language) else { return ""}
            let collection = getVectorCollection()
            guard let embedding = embed.vector(for: text) else { return ""}
            let results = collection.search(query: embedding)
            res = results.map{ $0.text }.joined(separator: "\n")
        } catch {
            print("search error, \(error.localizedDescription)")
        }
        return res
    }
    
    func generateEmbedding(_ urls: [URL]) throws {
        let collection = getVectorCollection()
        let fileManager = FileManager.default
        for url in urls {
            if url.hasDirectoryPath {
                try generateEmbedding(try fileManager
                    .contentsOfDirectory(at: url,
                                         includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]))
                continue
            }
            if !fileManager.fileExists(at: url) { continue }
            let document = try url.readContent()
            guard let language = NLLanguageRecognizer.dominantLanguage(for: document) else { continue }
            guard let embed = NLEmbedding.sentenceEmbedding(for: language) else { continue }
            guard let embedding = embed.vector(for: document) else { continue }
            collection.addDocument(text: document, embedding: embedding)
        }
    }
}
