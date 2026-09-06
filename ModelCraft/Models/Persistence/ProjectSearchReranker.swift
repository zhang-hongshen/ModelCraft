//
//  ProjectSearchReranker.swift
//  ModelCraft
//

import Foundation
import NaturalLanguage

struct ProjectSearchCandidate {
    let result: ProjectSearchResult
    let retrievalScore: Double
}

enum ProjectSearchReranker {
    static func rerank(
        query: String,
        purpose: ProjectSearchPurpose,
        candidates: [ProjectSearchCandidate],
        limit: Int
    ) -> [ProjectSearchResult] {
        let queryTokens = tokens(in: query)
        let queryEmbedding = NLEmbedding.sentenceEmbedding(for: query)?.map(Float.init)
        var merged: [String: ProjectSearchCandidate] = [:]

        for candidate in candidates {
            let key = "\(candidate.result.path)|\(candidate.result.location)"
            guard let existing = merged[key] else {
                merged[key] = candidate
                continue
            }
            let preferred = candidate.retrievalScore > existing.retrievalScore
                ? candidate.result : existing.result
            let reasons = Set(
                (existing.result.matchReason + "," + candidate.result.matchReason)
                    .split(separator: ",").map(String.init))
                .sorted().joined(separator: ",")
            merged[key] = ProjectSearchCandidate(
                result: ProjectSearchResult(
                    path: preferred.path,
                    source: preferred.source,
                    kind: preferred.kind,
                    location: preferred.location,
                    startLine: preferred.startLine,
                    endLine: preferred.endLine,
                    snippet: preferred.snippet,
                    matchReason: reasons),
                retrievalScore: max(existing.retrievalScore, candidate.retrievalScore)
                    + min(existing.retrievalScore, candidate.retrievalScore) * 0.2)
        }

        let rescored = merged.values.map { candidate -> (ProjectSearchCandidate, Double) in
            let result = candidate.result
            let searchable = "\(result.path) \(result.location) \(result.snippet)".lowercased()
            let matched = queryTokens.filter(searchable.contains)
            let coverage = queryTokens.isEmpty ? 0 : Double(matched.count) / Double(queryTokens.count)
            var score = candidate.retrievalScore + coverage * 18
            if let queryEmbedding,
               let resultEmbedding = NLEmbedding.sentenceEmbedding(
                for: "\(result.location)\n\(result.snippet)")?.map(Float.init),
               queryEmbedding.count == resultEmbedding.count {
                score += Double(cosine(queryEmbedding, resultEmbedding)) * 16
            }
            if searchable.contains(query.lowercased()) { score += 12 }
            if result.matchReason.contains("definition") { score += purpose == .locate || purpose == .edit ? 18 : 8 }
            if result.matchReason.contains("call_graph") { score += purpose == .edit ? 15 : 9 }
            if purpose == .understand && result.kind != "code" { score += 8 }
            if purpose == .edit && result.source == "reference" { score -= 14 }
            return (candidate, score)
        }.sorted { lhs, rhs in
            if lhs.1 == rhs.1 {
                return lhs.0.result.path.localizedStandardCompare(rhs.0.result.path) == .orderedAscending
            }
            return lhs.1 > rhs.1
        }

        var selected: [ProjectSearchResult] = []
        var deferred: [ProjectSearchResult] = []
        var perPath: [String: Int] = [:]
        for (candidate, _) in rescored {
            let pathCount = perPath[candidate.result.path, default: 0]
            if pathCount >= 2 && rescored.count > limit {
                deferred.append(candidate.result)
                continue
            }
            selected.append(candidate.result)
            perPath[candidate.result.path] = pathCount + 1
            if selected.count == limit { break }
        }
        if selected.count < limit {
            selected.append(contentsOf: deferred.prefix(limit - selected.count))
        }
        return selected
    }

    private static func tokens(in text: String) -> [String] {
        Array(Set(text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init)))
            .filter { !$0.isEmpty }
    }

    private static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var dot: Float = 0
        var lhsLength: Float = 0
        var rhsLength: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsLength += lhs[index] * lhs[index]
            rhsLength += rhs[index] * rhs[index]
        }
        guard lhsLength > 0, rhsLength > 0 else { return 0 }
        return dot / (sqrt(lhsLength) * sqrt(rhsLength))
    }
}
