//
//  CollectionManager.swift
//  ModelCraft
//
//  Created by Hongshen on 11/4/2024.
//

import Foundation
import NaturalLanguage

import SVDB

class CollectionManager {
    
    private let collection: Collection
    private let documentSpliiter = SemanticTextSplitter.default
    
    init(_ collectionName: String) {
        do {
            self.collection = try SVDB.shared.collection(collectionName)
        } catch {
            print("error, \(error.localizedDescription)")
            self.collection = SVDB.shared.getCollection(collectionName)!
        }
    }
    
    func addDocument(_ doc: String) {
        let chunks = documentSpliiter.createDocuments(doc)
        for chunk in chunks {
            guard let embedding = NLEmbedding.sentenceEmbedding(for: chunk) else { return }
            collection.addDocument(text: chunk, embedding: embedding)
        }
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
    
    func query( _ text: String, numOfResults: Int = 10) async -> [SearchResult] {
        
        let documents = documentSpliiter.createDocuments(text)
        let embeddings = documents.compactMap { NLEmbedding.sentenceEmbedding(for: $0) }
        
        let results = await withTaskGroup(of: [SearchResult].self) { group in
            for embedding in embeddings {
                group.addTask {
                    self.collection.search(
                        query: embedding,
                        num_results: numOfResults)
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
    
}
