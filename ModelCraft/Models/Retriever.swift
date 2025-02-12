//
//  Retriever.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 11/4/2024.
//

import Foundation
import NaturalLanguage

import SVDB

class Retriever {
    
    private let collection: Collection
    
    init(_ collectionName: String) {
        do {
            self.collection = try SVDB.shared.collection(collectionName)
        } catch {
            debugPrint("error, \(error.localizedDescription)")
            self.collection = SVDB.shared.getCollection(collectionName)!
        }
    }
    
    func addDocument(_ doc: String) {
        guard let embedding = createEmbedding(doc) else { return }
        collection.addDocument(text: doc, embedding: embedding)
    }
    
    func addDocuments(_ docs: [String]) {
        Task {
            await withTaskGroup(of: Void.self) { group in
                for doc in docs {
                    group.addTask {
                        self.addDocument(doc)
                    }
                }
            }
        }
    }
    
    func query( _ text: String) async -> [SearchResult] {
        
        let documents = TextSplitter.default.createDocuments(text)
        let embeddings = documents.compactMap { createEmbedding($0) }
        
        let results = await withTaskGroup(of: [SearchResult].self) { group in
            for embedding in embeddings {
                group.addTask {
                    self.collection.search(query: embedding)
                }
            }
            var allResults: [SearchResult] = []
            for await result in group {
                allResults.append(contentsOf: result)
            }
            return allResults
        }

        // remove duplicate documents and sorted by score
        return Array(
            Dictionary(grouping: results, by: \.id)
                .mapValues { $0.max(by: { $0.score < $1.score })! }
                .values
        ).sorted { $0.score > $1.score }
    }
    
    private func createEmbedding(_ text: String) -> [Double]? {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return nil }
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
        return embedding.vector(for: text)
    }
}
