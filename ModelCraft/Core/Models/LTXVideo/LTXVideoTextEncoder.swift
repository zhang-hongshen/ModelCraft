//
//  LTXVideoTextEncoder.swift
//  ModelCraft
//

import Foundation

import MLX
import MLXNN
import Tokenizers

public struct LTXVideoPromptEncoding {
    public let embeddings: MLXArray
    public let attentionMask: MLXArray
}

public final class LTXVideoTextEncoder: Module {
    @ModuleInfo(key: "wte") var tokenEmbedding: Embedding
    @ModuleInfo var encoder: T5Encoder

    public init(
        vocabSize: Int,
        dimensions: Int,
        kvDimensions: Int,
        ffDimensions: Int,
        numHeads: Int,
        numLayers: Int,
        layerNormEpsilon: Float,
        relativeAttentionNumBuckets: Int,
        relativeAttentionMaxDistance: Int,
        feedForwardProjection: String?
    ) {
        self._tokenEmbedding.wrappedValue = Embedding(
            embeddingCount: vocabSize,
            dimensions: dimensions
        )
        self._encoder.wrappedValue = T5Encoder(
            inputDim: dimensions,
            dimKv: kvDimensions,
            dimFf: ffDimensions,
            numHeads: numHeads,
            numLayers: numLayers,
            layerNormEpsilon: layerNormEpsilon,
            relativeAttentionNumBuckets: relativeAttentionNumBuckets,
            relativeAttentionMaxDistance: relativeAttentionMaxDistance,
            feedForwardProj: feedForwardProjection
        )
    }

    public static func t5XXL() -> LTXVideoTextEncoder {
        LTXVideoTextEncoder(
            vocabSize: 32_128,
            dimensions: 4096,
            kvDimensions: 64,
            ffDimensions: 10_240,
            numHeads: 64,
            numLayers: 24,
            layerNormEpsilon: 1e-6,
            relativeAttentionNumBuckets: 32,
            relativeAttentionMaxDistance: 128,
            feedForwardProjection: "gated-gelu"
        )
    }

    public func encode(inputIDs: MLXArray) -> MLXArray {
        encoder(tokenEmbedding(inputIDs))
    }

    public static func sanitize(_ weights: [String: MLXArray]) -> [String: MLXArray] {
        var result: [String: MLXArray] = [:]

        for (key, value) in weights {
            var newKey = key
            if newKey.hasPrefix("text_encoder.") {
                newKey.removeFirst("text_encoder.".count)
            }
            newKey = newKey.replacingOccurrences(of: "shared.", with: "wte.")
            newKey = newKey.replacingOccurrences(of: "encoder.block.", with: "encoder.layers.")
            newKey = newKey.replacingOccurrences(of: ".layer.0.SelfAttention.", with: ".attention.")
            newKey = newKey.replacingOccurrences(of: ".layer.1.DenseReluDense.", with: ".dense.")
            newKey = newKey.replacingOccurrences(of: ".layer.0.layer_norm.", with: ".ln1.")
            newKey = newKey.replacingOccurrences(of: ".layer.1.layer_norm.", with: ".ln2.")
            newKey = newKey.replacingOccurrences(of: ".final_layer_norm.", with: ".ln.")
            newKey = newKey.replacingOccurrences(of: ".q.", with: ".query_proj.")
            newKey = newKey.replacingOccurrences(of: ".k.", with: ".key_proj.")
            newKey = newKey.replacingOccurrences(of: ".v.", with: ".value_proj.")
            newKey = newKey.replacingOccurrences(of: ".o.", with: ".out_proj.")
            newKey = newKey.replacingOccurrences(
                of: "encoder.layers.0.attention.relative_attention_bias.",
                with: "encoder.relative_attention_bias.embeddings."
            )

            if newKey.hasPrefix("decoder.") || newKey.hasPrefix("lm_head.") {
                continue
            }
            result[newKey] = value
        }

        return result
    }
}

public final class LTXVideoTokenizer {
    private let tokenizer: Tokenizer
    private let padTokenID = 0
    private let eosTokenID = 1

    public init(tokenizer: Tokenizer) {
        self.tokenizer = tokenizer
    }

    public func encode(_ text: String, maxLength: Int) -> (ids: MLXArray, mask: MLXArray) {
        var ids = tokenizer.encode(text: text)
        if ids.last != eosTokenID {
            ids.append(eosTokenID)
        }
        if ids.count > maxLength {
            ids = Array(ids.prefix(maxLength))
            ids[maxLength - 1] = eosTokenID
        }

        let validCount = ids.count
        if ids.count < maxLength {
            ids.append(contentsOf: Array(repeating: padTokenID, count: maxLength - ids.count))
        }

        let maskValues = (0..<maxLength).map { $0 < validCount ? Int32(1) : Int32(0) }
        return (
            MLXArray(ids.map(Int32.init)).reshaped([1, maxLength]),
            MLXArray(maskValues).reshaped([1, maxLength])
        )
    }
}

