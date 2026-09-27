//
//  DeepSeekFlashTokenizer.swift
//  ModelCraft
//
//  Created by Hongshen on 26/9/26.
//

import Foundation
import Hub
import Tokenizers
import MLXLMCommon

final class DeepSeekFlashTokenizer {
    static let imagePlaceholder = "<｜deepseek_image｜>"
    private let tokenizer: Tokenizer

    init(hub: HubApi, directory: URL) async throws {
        let tokenizerData = try hub.configuration(
            fileURL: directory.appending(component: "tokenizer.json"))
        let tokenizerConfiguration = try hub.configuration(
            fileURL: directory.appending(component: "tokenizer_config.json"))
        tokenizer = try AutoTokenizer.from(
            tokenizerConfig: tokenizerConfiguration,
            tokenizerData: tokenizerData)
    }

    var endOfSentenceTokenID: Int {
        tokenizer.eosTokenId ?? 1
    }

    func encode(text: String) -> [Int] {
        tokenizer.encode(text: text)
    }

    var imagePlaceholderTokenID: Int {
        let ids = encode(text: Self.imagePlaceholder)
        precondition(ids.count == 1, "DeepSeek image placeholder must be one token")
        return ids[0]
    }

    func decode(tokens: [Int]) -> String {
        tokenizer.decode(tokens: tokens)
    }

    func makeStreamingDecoder() -> StreamingDecoder {
        StreamingDecoder(tokenizer: tokenizer)
    }

    final class StreamingDecoder {
        private var detokenizer: NaiveStreamingDetokenizer

        fileprivate init(tokenizer: Tokenizer) {
            detokenizer = NaiveStreamingDetokenizer(tokenizer: tokenizer)
        }

        func append(token: Int) -> String? {
            detokenizer.append(token: token)
            return detokenizer.next()
        }
    }

}
