//
//  H3Tokenizer.swift
//  ModelCraft
//
//  Created by Hongshen on 27/8/26.
//


import Foundation
import Hub


/// Qwen2 byte-level BPE — the tokenizer H3's conditioning encoder expects.
///
/// MiniMax-H3 uses it in its plainest form. `MiniMaxH3Tokenizer` in the
/// reference calls `tok(text, add_special_tokens=False)` and adds **nothing**:
/// no chat template, no BOS, no EOS. The `<|im_start|>user\n…` wrapper that
/// other Qwen3-VL consumers apply is not used here, and adding it would shift
/// every position and change the conditioning.
///
/// Empty input is the one special case: the reference substitutes a single pad
/// token (151643) rather than an empty sequence.
struct H3Tokenizer {
    let vocab: [String: Int]
    let ranks: [Pair: Int]
    /// Added/special tokens, longest first so `<|im_start|>` wins over `<`.
    let specials: [(text: String, id: Int)]
    static let padToken = 151_643

    struct Pair: Hashable {
        let a: String, b: String
        init(_ a: String, _ b: String) { self.a = a; self.b = b }
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case missing(String)
        var description: String {
            switch self {
            case .missing(let p): "tokenizer file not found: \(p)"
            }
        }
    }

    /// GPT-2's byte-to-unicode table: every byte becomes a printable code point
    /// so BPE can run over text without ever seeing a control character.
    static let byteEncoder: [UInt8: Character] = {
        var bs: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) {
            bs.append(b); cs.append(256 + n); n += 1
        }
        var map: [UInt8: Character] = [:]
        for (b, c) in zip(bs, cs) { map[UInt8(b)] = Character(UnicodeScalar(c)!) }
        return map
    }()

    init(directory: URL) throws {
        let vocabURL = directory.appendingPathComponent("vocab.json")
        let mergesURL = directory.appendingPathComponent("merges.txt")
        guard let vd = try? Data(contentsOf: vocabURL) else {
            throw Error.missing(vocabURL.path)
        }
        guard let raw = try? String(contentsOf: mergesURL, encoding: .utf8) else {
            throw Error.missing(mergesURL.path)
        }
        guard let v = try JSONSerialization.jsonObject(with: vd) as? [String: Int] else {
            throw Error.missing("vocab.json is not a {string: int} map")
        }
        self.vocab = v

        var r: [Pair: Int] = [:]
        var i = 0
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#version") { continue }
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            r[Pair(String(parts[0]), String(parts[1]))] = i
            i += 1
        }
        self.ranks = r

        // Added tokens are NOT in vocab.json — it stops at 151643 and the 26
        // control tokens live in tokenizer_config.json's added_tokens_decoder.
        // Filtering vocab.json for <|…|> finds nothing, and "<|im_start|>" then
        // byte-splits into 6 ordinary tokens instead of one.
        var added: [(String, Int)] = []
        let cfgURL = directory.appendingPathComponent("tokenizer_config.json")
        if let cd = try? Data(contentsOf: cfgURL),
           let cfg = try? JSONSerialization.jsonObject(with: cd) as? [String: Any],
           let decoder = cfg["added_tokens_decoder"] as? [String: Any] {
            for (idString, entry) in decoder {
                guard let id = Int(idString),
                      let e = entry as? [String: Any],
                      let content = e["content"] as? String else { continue }
                added.append((content, id))
            }
        }
        // Longest first so `<|im_start|>` wins over any prefix of it.
        self.specials = added.sorted { $0.0.count > $1.0.count }
    }

    init(hub: HubApi, configuration: H3Configuration) throws {
        let vocabulary = try H3Loader.resolve(
            hub: hub,
            configuration: configuration,
            key: .tokenizerVocabulary)
        try self.init(directory: vocabulary.deletingLastPathComponent())
    }

    /// The pre-tokenizer split, from `transformers`' Qwen2 implementation.
    ///
    /// Order matters and so does every alternative: contractions first, then
    /// letters (with one optional leading non-letter), then digits **one at a
    /// time**, then punctuation runs, then the three whitespace cases. Getting
    /// the digit rule wrong is invisible on prose and wrong on "1234567890".
    static let pattern =
        "(?i:'s|'t|'re|'ve|'m|'ll|'d)"
        + "|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+"
        + "|\\p{N}"
        + "| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*"
        + "|\\s*[\\r\\n]+"
        + "|\\s+(?!\\S)"
        + "|\\s+"

    static let regex = try! NSRegularExpression(pattern: pattern)

    /// One BPE word: byte-encoded, then merged by rank until nothing matches.
    func bpe(_ token: String) -> [String] {
        var symbols = token.map(String.init)
        if symbols.count < 2 { return symbols }
        while true {
            var best: (rank: Int, index: Int)? = nil
            for i in 0 ..< (symbols.count - 1) {
                if let rank = ranks[Pair(symbols[i], symbols[i + 1])],
                   best == nil || rank < best!.rank {
                    best = (rank, i)
                }
            }
            guard let b = best else { break }
            symbols.replaceSubrange(b.index ... (b.index + 1),
                                    with: [symbols[b.index] + symbols[b.index + 1]])
            if symbols.count == 1 { break }
        }
        return symbols
    }

    private func encodeChunk(_ text: String) -> [Int] {
        guard !text.isEmpty else { return [] }
        var ids: [Int] = []
        let ns = text as NSString
        let matches = Self.regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let piece = ns.substring(with: m.range)
            let encoded = String(Array(piece.utf8).compactMap { Self.byteEncoder[$0] })
            for symbol in bpe(encoded) {
                if let id = vocab[symbol] { ids.append(id) }
            }
        }
        return ids
    }

    /// `add_special_tokens=False`, exactly as the reference calls it.
    func encode(_ text: String) -> [Int] {
        guard !text.isEmpty else { return [] }
        // Split around literal special tokens first; everything between them
        // goes through the byte-level path.
        var ids: [Int] = []
        var rest = Substring(text)
        outer: while !rest.isEmpty {
            for (s, id) in specials {
                if let r = rest.range(of: s) {
                    ids += encodeChunk(String(rest[rest.startIndex ..< r.lowerBound]))
                    ids.append(id)
                    rest = rest[r.upperBound...]
                    continue outer
                }
            }
            ids += encodeChunk(String(rest))
            break
        }
        return ids
    }

    /// What the reference feeds the encoder: the prompt's ids, or a single pad
    /// token when the prompt is empty.
    func encodePrompt(_ text: String) -> [Int] {
        let ids = encode(text)
        return ids.isEmpty ? [Self.padToken] : ids
    }

    /// Returns an id from the downloaded tokenizer configuration. H3's vision
    /// boundary tokens are added tokens rather than ordinary vocabulary
    /// entries, so callers must not assume their numeric ids are portable
    /// across tokenizer revisions.
    func tokenID(for content: String) -> Int? {
        specials.first(where: { $0.text == content })?.id ?? vocab[content]
    }

    /// Modality tag per token. A pure-text prompt is all 1 (text); vision pads
    /// would carry 0 (video), which is why this is a per-token array and not a
    /// constant.
    func textTags(count: Int) -> [Int] { Array(repeating: 1, count: count) }
}
