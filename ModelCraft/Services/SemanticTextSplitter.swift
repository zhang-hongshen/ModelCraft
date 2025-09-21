//
//  SemanticTextSplitter.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 13/9/25.
//


import Foundation
import NaturalLanguage

/// Semantic text splitter:
/// Split text into sentences, embed each, compute similarities,
/// cut when similarity drops below threshold or drops suddenly.
public final class SemanticTextSplitter {
    public typealias EmbeddingFn = (String) -> [Double]?

    private let embed: EmbeddingFn
    private let simThreshold: Double
    private let dropThreshold: Double
    private let fallbackChars: Int

    public static let `default` = SemanticTextSplitter(
        embedding: NLEmbedding.sentenceEmbedding)
    
    public init(
        embedding: @escaping EmbeddingFn,
        simThreshold: Double = 0.55,
        dropThreshold: Double = 0.25,
        fallbackChars: Int = 500,
    ) {
        self.embed = embedding
        self.simThreshold = simThreshold
        self.dropThreshold = dropThreshold
        self.fallbackChars = max(1, fallbackChars)
        
    }

    public func createDocuments(_ text: String) -> [String] {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return [] }
        let sents = splitSentences(text, language: language)
        guard !sents.isEmpty else { return [] }

        let embeddings = sents.compactMap{ embed($0) ?? nil}
        if embeddings.allSatisfy({ $0.isEmpty }) {
            return fixedSplitByCharacters(text, size: fallbackChars)
        }

        var sims: [Double] = [1.0]
        for i in 1..<embeddings.count {
            sims.append(cosine(embeddings[i-1], embeddings[i]))
        }

        var chunks: [String] = []
        var start = 0
        for i in 1..<sents.count {
            let cur = sims[i]
            let prev = sims[i-1]
            let suddenDrop = (prev - cur) >= dropThreshold
            if (cur < simThreshold) || suddenDrop {
                chunks.append(joinRange(sents, start..<i))
                start = i
            }
        }
        chunks.append(joinRange(sents, start..<sents.count))
        return chunks
    }

    private func splitSentences(_ text: String, language: NLLanguage?) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        let tok = NLTokenizer(unit: .sentence)
        if let lang = language { tok.setLanguage(lang) }
        tok.string = t
        var out: [String] = []
        tok.enumerateTokens(in: t.startIndex..<t.endIndex) { r, _ in
            let s = t[r].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            return true
        }
        return out
    }

    private func joinRange(_ sents: [String], _ r: Range<Int>) -> String {
        sents[r].joined(separator: " ")
    }

    private func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard !a.isEmpty, !b.isEmpty, a.count == b.count else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count { dot += a[i]*b[i]; na += a[i]*a[i]; nb += b[i]*b[i] }
        if na == 0 || nb == 0 { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }

    private func fixedSplitByCharacters(_ text: String, size: Int) -> [String] {
        var res: [String] = []; var i = text.startIndex
        while i < text.endIndex {
            let j = text.index(i, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            res.append(String(text[i..<j])); i = j
        }
        return res
    }
}
