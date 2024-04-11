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
        guard let embedding = embed(doc) else { return }
        collection.addDocument(text: doc, embedding: embedding)
    }
    
    func addDocuments(_ docs: [String]) {
        docs.forEach { doc in
            addDocument(doc)
        }
    }
    
    func query( _ text: String) -> [SearchResult] {
        guard let embedding = embed(text) else { return [] }
        return collection.search(query: embedding)
    }
    
    private func embed(_ text: String) -> [Double]? {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return nil }
        guard let embed = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
        return embed.vector(for: text)
    }
}
