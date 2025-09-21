//
//  NLEmbedding.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 21/9/25.
//

import NaturalLanguage

extension NLEmbedding {
    
    static func sentenceEmbedding(for text: String) -> [Double]? {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return nil }
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
        return embedding.vector(for: text)
    }
    
}
