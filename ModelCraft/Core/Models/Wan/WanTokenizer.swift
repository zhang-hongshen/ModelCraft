//
//  WanTokenizer.swift
//  ModelCraft
//
//  Created by Hongshen on 9/4/26.
//

import Foundation
import MLX
import Tokenizers

/// T5 tokenizer for Wan2.1.
public final class T5Tokenizer {
    public let tokenizer: Tokenizer
    public let padTokenID: Int

    public init(tokenizerURL: URL) async throws {
        self.tokenizer = try await AutoTokenizer.from(modelFolder: tokenizerURL)
        self.padTokenID = tokenizer.convertTokenToId("<pad>") ?? 0
    }

    public func encode(
        _ text: String,
        maxLength: Int = 512,
        padding: Bool = true,
        truncation: Bool = true
    ) throws -> T5Tokenized {
        var ids = self.tokenizer.encode(text: text)
        
        if truncation && ids.count > maxLength {
            ids = Array(ids.prefix(maxLength))
        }

        var attentionMask = Array(repeating: 1, count: ids.count)
        if padding && ids.count < maxLength {
            let padLen = maxLength - ids.count
            ids.append(contentsOf: repeatElement(padTokenID, count: padLen))
            attentionMask.append(contentsOf: repeatElement(0, count: padLen))
        }

        return T5Tokenized(
            inputIDs: MLXArray(ids).expandedDimensions(axis: 0).asType(.int32),
            attentionMask: MLXArray(attentionMask).expandedDimensions(axis: 0).asType(.int32)
        )
    }
}

public struct T5Tokenized {
    public let inputIDs: MLXArray
    public let attentionMask: MLXArray
}
