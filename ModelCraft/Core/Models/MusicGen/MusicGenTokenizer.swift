//
//  MusicGenTokenizer.swift
//  ModelCraft
//
//  Created by Hongshen on 23/5/26.
//

import MLX
import Hub
import Tokenizers

public class MusicGenTokenizer {
    let decoderStartTokenId: Int
    private let tokenizer: Tokenizer

    init(decoderStartTokenId: Int, tokenizerData: Config, tokenizerConfig: Config) throws {
        self.decoderStartTokenId = decoderStartTokenId
        
        self.tokenizer = try AutoTokenizer.from(tokenizerConfig: tokenizerConfig, tokenizerData: tokenizerData)
    }

    var eosTokenId: Int {
        tokenizer.eosTokenId ?? 1
    }

    func encode(_ text: String) -> MLXArray {
        let ids = tokenizer.encode(text: text)
        return MLXArray(ids).reshaped(1, -1)
    }

    func decode(_ tokens: [Int], withSep: Bool = true) -> String {
        return tokenizer.decode(tokens: tokens)
    }
}
