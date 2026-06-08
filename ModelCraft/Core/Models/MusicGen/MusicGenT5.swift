// Copyright © 2024 Apple Inc.

import Foundation
import MLX
import MLXNN
import MLXFast


public class MusicGenT5: Module {
    
    @ModuleInfo var wte: Embedding
    @ModuleInfo var encoder: T5Encoder
    @ModuleInfo var decoder: T5Decoder
    @ModuleInfo(key: "lm_head") var lmHead: Linear?
    
    let tieWordEmbeddings: Bool
    let modelDim: Int
    
    public init(inputDim: Int, dimKv: Int, dimFf: Int, numHeads: Int,
         numLayers: Int, numDecoderLayers: Int, layerNormEpsilon: Float,
         relativeAttentionNumBuckets: Int, relativeAttentionMaxDistance: Int,
        decoderStartTokenId: Int, tieWordEmbeddings: Bool, vocabSize: Int, feedForwardProj: String?) {
        self._wte.wrappedValue = Embedding(
            embeddingCount: vocabSize,
            dimensions: inputDim
        )
        self._encoder.wrappedValue = T5Encoder(inputDim: inputDim, dimKv: dimKv, dimFf: dimFf, numHeads: numHeads, numLayers: numLayers, layerNormEpsilon: layerNormEpsilon, relativeAttentionNumBuckets: relativeAttentionNumBuckets, relativeAttentionMaxDistance: relativeAttentionMaxDistance, feedForwardProj: feedForwardProj)
        
        self._decoder.wrappedValue = T5Decoder(inputDim: inputDim, dimKv: dimKv, dimFf: dimFf, numHeads: numHeads, numLayers: numLayers, numDecoderLayers: numDecoderLayers, layerNormEpsilon: layerNormEpsilon, relativeAttentionNumBuckets: relativeAttentionNumBuckets, relativeAttentionMaxDistance: relativeAttentionMaxDistance, feedForwardProj: feedForwardProj)
        self.tieWordEmbeddings = tieWordEmbeddings
        
        if !self.tieWordEmbeddings {
            self._lmHead.wrappedValue = Linear(inputDim, vocabSize, bias: false)
        }
        self.modelDim = inputDim
        super.init()
    }

    func encode(_ inputs: MLXArray) -> MLXArray {
        encoder(wte(inputs))
    }

    func decode(
        _ inputs: MLXArray,
        memory: MLXArray,
        cache: [(MLXArray, MLXArray)]? = nil
    ) -> (MLXArray, [(MLXArray, MLXArray)]) {
        let x = wte(inputs)
        let T = x.dim(1)
        let mask: MLXArray?
        if T > 1 {
            mask = MultiHeadAttention.createAdditiveCausalMask(T).asType(x.dtype)
        } else {
            mask = nil
        }

        let (y, newCache) = decoder(x, memory: memory, mask: mask, memoryMask: nil, cache: cache)
        var output = y
        if !tieWordEmbeddings, let lmHead = lmHead {
            output = lmHead(y)
        } else {
            output = y * pow(Float(modelDim), -0.5)
            output = matmul(output, wte.weight.T)
        }
        return (output, newCache)
    }

    // MARK: - Weight Sanitization

    static func sanitize(_ weights: [String: MLXArray]) -> [String: MLXArray] {
        let sharedReplacements: [(String, String)] = [
            (".block.", ".layers."),
            (".k.", ".key_proj."),
            (".o.", ".out_proj."),
            (".q.", ".query_proj."),
            (".v.", ".value_proj."),
            ("shared.", "wte."),
            ("lm_head.", "lm_head.linear."),
            (".layer.0.layer_norm.", ".ln1."),
            (".layer.1.layer_norm.", ".ln2."),
            (".layer.2.layer_norm.", ".ln3."),
            (".final_layer_norm.", ".ln."),
            (
                "layers.0.layer.0.SelfAttention.relative_attention_bias.",
                "relative_attention_bias.embeddings."
            ),
        ]

        let encoderReplacements: [(String, String)] = [
            (".layer.0.SelfAttention.", ".attention."),
            (".layer.1.DenseReluDense.", ".dense."),
        ]

        let decoderReplacements: [(String, String)] = [
            (".layer.0.SelfAttention.", ".self_attention."),
            (".layer.1.EncDecAttention.", ".cross_attention."),
            (".layer.2.DenseReluDense.", ".dense."),
        ]

        let ignoredKeys = Set([
            "decoder.layers.0.cross_attention.relative_attention_bias.weight"
        ])

        var result: [String: MLXArray] = [:]

        for (key, value) in weights {
            var newKey = key
            for (old, new) in sharedReplacements {
                newKey = newKey.replacingOccurrences(of: old, with: new)
            }
            if newKey.hasPrefix("encoder.") {
                for (old, new) in encoderReplacements {
                    newKey = newKey.replacingOccurrences(of: old, with: new)
                }
            } else if newKey.hasPrefix("decoder.") {
                for (old, new) in decoderReplacements {
                    newKey = newKey.replacingOccurrences(of: old, with: new)
                }
            }

            if !ignoredKeys.contains(newKey) {
                result[newKey] = value
            }
        }

        return result
    }
}


class T5RelativePositionBias: Module {
    let bidirectional: Bool
    let numBuckets: Int
    let maxDistance: Int
    let nHeads: Int
    @ModuleInfo var embeddings: Embedding

    init(numHeads: Int, relativeAttentionNumBuckets: Int,
         relativeAttentionMaxDistance: Int, bidirectional: Bool) {
        self.bidirectional = bidirectional
        self.numBuckets = relativeAttentionNumBuckets
        self.maxDistance = relativeAttentionMaxDistance
        self.nHeads = numHeads
        self.embeddings = Embedding(
            embeddingCount: relativeAttentionNumBuckets,
            dimensions: numHeads
        )
    }

    // MARK: - Relative Position Bias

    private func relativePositionBucket(
        relativePosition: MLXArray,
        bidirectional: Bool = true,
        numBuckets: Int = 32,
        maxDistance: Int = 128
    ) -> MLXArray {
        var numBuckets = numBuckets
        var relativeBuckets = MLXArray(0)

        if bidirectional {
            numBuckets /= 2
            relativeBuckets = relativeBuckets + (relativePosition .> 0).asType(.int16) * MLXArray(numBuckets)
            let relativePosition = abs(relativePosition)

            let maxExact = numBuckets / 2
            let isSmall = relativePosition .< MLXArray(maxExact)

            let scale = Float(numBuckets - maxExact) / log(Float(maxDistance) / Float(maxExact))
            let relativePositionIfLarge = MLXArray(maxExact) + (
                log(relativePosition.asType(.float32) / Float(maxExact)) * scale
            ).asType(.int16)
            let clampedLarge = minimum(relativePositionIfLarge, MLXArray(numBuckets - 1))
            relativeBuckets = relativeBuckets + which(isSmall, relativePosition, clampedLarge)

            return relativeBuckets
        } else {
            let relativePosition = -minimum(relativePosition, MLXArray.zeros(like: relativePosition))

            let maxExact = numBuckets / 2
            let isSmall = relativePosition .< MLXArray(maxExact)

            let scale = Float(numBuckets - maxExact) / log(Float(maxDistance) / Float(maxExact))
            let relativePositionIfLarge = MLXArray(maxExact) + (
                log(relativePosition.asType(.float32) / Float(maxExact)) * scale
            ).asType(.int16)
            let clampedLarge = minimum(relativePositionIfLarge, MLXArray(numBuckets - 1))
            relativeBuckets = relativeBuckets + which(isSmall, relativePosition, clampedLarge)

            return relativeBuckets
        }
    }
    
    func callAsFunction(queryLength: Int, keyLength: Int, offset: Int = 0) -> MLXArray {
        let contextPosition = MLXArray(Int32(offset) ..< Int32(queryLength)).reshaped(-1, 1)
        let memoryPosition = MLXArray(0 ..< Int32(keyLength)).reshaped(1, -1)

        let relativePosition = memoryPosition - contextPosition
        let bucket = relativePositionBucket(
            relativePosition: relativePosition,
            bidirectional: bidirectional,
            numBuckets: numBuckets,
            maxDistance: maxDistance
        )

        // shape: (query_length, key_length, num_heads)
        let values = embeddings(bucket)
        // shape: (num_heads, query_length, key_length)
        return values.transposed(2, 0, 1)
    }
}

// MARK: - T5 Multi-Head Attention

class T5MultiHeadAttention: Module {
    let numHeads: Int
    @ModuleInfo(key: "query_proj") var queryProj: Linear
    @ModuleInfo(key: "key_proj") var keyProj: Linear
    @ModuleInfo(key: "value_proj") var valueProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear

    init(inputDim: Int, dimKv: Int, numHeads: Int) {
        let innerDim = dimKv * numHeads
        self.numHeads = numHeads
        self._queryProj.wrappedValue = Linear(inputDim, innerDim, bias: false)
        self._keyProj.wrappedValue = Linear(inputDim, innerDim, bias: false)
        self._valueProj.wrappedValue = Linear(inputDim, innerDim, bias: false)
        self._outProj.wrappedValue = Linear(innerDim, inputDim, bias: false)
    }

    func callAsFunction(
        queries: MLXArray,
        keys: MLXArray,
        values: MLXArray,
        mask: MLXArray?,
        cache: (MLXArray, MLXArray)? = nil
    ) -> (MLXArray, (MLXArray, MLXArray)) {
        var q = queryProj(queries)
        var k = keyProj(keys)
        var v = valueProj(values)

        let B = q.dim(0)
        let Lq = q.dim(1)
        let S = k.dim(1)

        q = q.reshaped(B, Lq, numHeads, -1).transposed(0, 2, 1, 3)
        k = k.reshaped(B, S, numHeads, -1).transposed(0, 2, 3, 1)
        v = v.reshaped(B, S, numHeads, -1).transposed(0, 2, 1, 3)

        if let cache = cache {
            k = concatenated([cache.0, k], axis: 3)
            v = concatenated([cache.1, v], axis: 2)
        }

        var scores = matmul(q, k)
        if let mask = mask {
            scores = scores + mask.asType(scores.dtype)
        }

        scores = softmax(scores.asType(.float32), axis: -1).asType(scores.dtype)
        let valuesHat = matmul(scores, v).transposed(0, 2, 1, 3).reshaped(B, Lq, -1)
        return (outProj(valuesHat), (k, v))
    }
}

// MARK: - Dense Activation

class T5DenseActivation: Module {
    let gated: Bool
    @ModuleInfo(key: "wi_0") var wi0: Linear?
    @ModuleInfo(key: "wi_1") var wi1: Linear?
    @ModuleInfo(key: "wi") var wi: Linear?
    @ModuleInfo(key: "wo") var wo: Linear
    let act: (MLXArray) -> MLXArray

    init(inputDim: Int, dimFf: Int, feedForwardProj: String?) {
        let mlpDims = dimFf
        self.gated = feedForwardProj != nil

        let activationName: String
        if let proj = feedForwardProj {
            activationName = proj.replacingOccurrences(of: "gated-", with: "")
        } else {
            activationName = "relu"
        }

        switch activationName {
        case "relu": self.act = { relu($0) }
        case "gelu": self.act = { gelu($0) }
        case "silu": self.act = { silu($0) }
        default: self.act = { relu($0) }
        }

        if gated {
            self._wi0.wrappedValue = Linear(inputDim, mlpDims, bias: false)
            self._wi1.wrappedValue = Linear(inputDim, mlpDims, bias: false)
            self._wi.wrappedValue = nil
        } else {
            self._wi0.wrappedValue = nil
            self._wi1.wrappedValue = nil
            self._wi.wrappedValue = Linear(inputDim, mlpDims, bias: false)
        }
        self._wo.wrappedValue = Linear(mlpDims, inputDim, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        if gated, let wi0 = wi0, let wi1 = wi1 {
            let hiddenAct = act(wi0(x))
            let hiddenLinear = wi1(x)
            return wo(hiddenAct * hiddenLinear)
        } else if let wi = wi {
            return wo(act(wi(x)))
        }
        fatalError("Invalid DenseActivation configuration")
    }
}

// MARK: - Encoder Layer

class T5EncoderLayer: Module {
    @ModuleInfo var attention: T5MultiHeadAttention
    @ModuleInfo var ln1: RMSNorm
    @ModuleInfo var ln2: RMSNorm
    @ModuleInfo var dense: T5DenseActivation

    init(inputDim: Int, dimKv: Int, dimFf: Int, numHeads: Int, layerNormEpsilon: Float, feedForwardProj: String?) {
        self.attention = T5MultiHeadAttention(inputDim: inputDim, dimKv: dimKv, numHeads: numHeads)
        self.ln1 = RMSNorm(dimensions: inputDim, eps: layerNormEpsilon)
        self.ln2 = RMSNorm(dimensions: inputDim, eps: layerNormEpsilon)
        self.dense = T5DenseActivation(inputDim: inputDim, dimFf: dimFf, feedForwardProj: feedForwardProj)
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray) -> MLXArray {
        var x = x
        let y1 = ln1(x)
        let (attnOut, _) = attention(queries: y1, keys: y1, values: y1, mask: mask)
        x = x + attnOut

        let y2 = ln2(x)
        return x + dense(y2)
    }
}

// MARK: - Encoder

class T5Encoder: Module {
    @ModuleInfo var layers: [T5EncoderLayer]
    @ModuleInfo var ln: RMSNorm
    @ModuleInfo(key: "relative_attention_bias") var relativeAttentionBias: T5RelativePositionBias

    init(inputDim: Int, dimKv: Int, dimFf: Int, numHeads: Int, numLayers: Int, layerNormEpsilon: Float,
         relativeAttentionNumBuckets: Int, relativeAttentionMaxDistance: Int, feedForwardProj: String?) {
        
        self._layers.wrappedValue = Array(repeating: (), count: numLayers).map { _ in
            T5EncoderLayer(inputDim: inputDim, dimKv: dimKv, dimFf: dimFf,
                           numHeads: numHeads, layerNormEpsilon: layerNormEpsilon, feedForwardProj: feedForwardProj)
        }
        self._ln.wrappedValue = RMSNorm(dimensions: inputDim, eps: layerNormEpsilon)
        self._relativeAttentionBias.wrappedValue = T5RelativePositionBias(numHeads: numHeads, relativeAttentionNumBuckets: relativeAttentionNumBuckets, relativeAttentionMaxDistance: relativeAttentionMaxDistance, bidirectional: true)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let posBias = relativeAttentionBias(queryLength: x.dim(1), keyLength: x.dim(1))
        var x = x
        for layer in layers {
            x = layer(x, mask: posBias)
        }
        return ln(x)
    }
}

// MARK: - Decoder Layer

class T5DecoderLayer: Module {
    @ModuleInfo(key: "self_attention") var selfAttention: T5MultiHeadAttention
    @ModuleInfo(key: "cross_attention") var crossAttention: T5MultiHeadAttention
    @ModuleInfo var ln1: RMSNorm
    @ModuleInfo var ln2: RMSNorm
    @ModuleInfo var ln3: RMSNorm
    @ModuleInfo var dense: T5DenseActivation

    init(inputDim: Int, dimKv: Int, dimFf: Int, numHeads: Int, layerNormEpsilon: Float, feedForwardProj: String?) {
        self._selfAttention.wrappedValue = T5MultiHeadAttention(inputDim: inputDim, dimKv: dimKv, numHeads: numHeads)
        self._crossAttention.wrappedValue = T5MultiHeadAttention(inputDim: inputDim, dimKv: dimKv, numHeads: numHeads)
        self._ln1.wrappedValue = RMSNorm(dimensions: inputDim, eps: layerNormEpsilon)
        self._ln2.wrappedValue = RMSNorm(dimensions: inputDim, eps: layerNormEpsilon)
        self._ln3.wrappedValue = RMSNorm(dimensions: inputDim, eps: layerNormEpsilon)
        self._dense.wrappedValue = T5DenseActivation(inputDim: inputDim, dimFf: dimFf, feedForwardProj: feedForwardProj)
    }

    func callAsFunction(
        _ x: MLXArray,
        memory: MLXArray,
        mask: MLXArray?,
        memoryMask: MLXArray?,
        cache: (MLXArray, MLXArray)? = nil
    ) -> (MLXArray, (MLXArray, MLXArray)) {
        var x = x
        let y1 = ln1(x)
        let (selfAttnOut, newCache) = selfAttention(
            queries: y1, keys: y1, values: y1, mask: mask, cache: cache
        )
        x = x + selfAttnOut

        let y2 = ln2(x)
        let (crossAttnOut, _) = crossAttention(
            queries: y2, keys: memory, values: memory, mask: memoryMask
        )
        x = x + crossAttnOut

        let y3 = ln3(x)
        x = x + dense(y3)

        return (x, newCache)
    }
}

// MARK: - Decoder

class T5Decoder: Module {
    @ModuleInfo var layers: [T5DecoderLayer]
    @ModuleInfo var ln: RMSNorm
    @ModuleInfo(key: "relative_attention_bias") var relativeAttentionBias: T5RelativePositionBias

    init(inputDim: Int, dimKv: Int, dimFf: Int, numHeads: Int, numLayers: Int, numDecoderLayers: Int, layerNormEpsilon: Float,
         relativeAttentionNumBuckets: Int, relativeAttentionMaxDistance: Int, feedForwardProj: String?) {
        
        self._layers.wrappedValue = Array(repeating: (), count: numDecoderLayers).map { _ in
            T5DecoderLayer(inputDim: inputDim, dimKv: dimKv, dimFf: dimFf, numHeads: numHeads, layerNormEpsilon: layerNormEpsilon, feedForwardProj: feedForwardProj)
        }
        self._ln.wrappedValue = RMSNorm(dimensions: inputDim, eps: layerNormEpsilon)
        self._relativeAttentionBias.wrappedValue = T5RelativePositionBias(numHeads: numHeads, relativeAttentionNumBuckets: relativeAttentionNumBuckets, relativeAttentionMaxDistance: relativeAttentionMaxDistance, bidirectional: false)
    }

    func callAsFunction(
        _ x: MLXArray,
        memory: MLXArray,
        mask: MLXArray?,
        memoryMask: MLXArray?,
        cache: [((MLXArray, MLXArray))]? = nil
    ) -> (MLXArray, [(MLXArray, MLXArray)]) {
        let cache = cache ?? Array(repeating: nil as (MLXArray, MLXArray)?, count: layers.count)
        let offset: Int
        if let firstCache = cache.first, let c = firstCache {
            offset = c.0.dim(3)
        } else {
            offset = 0
        }

        let T = offset + x.dim(1)
        let posBias = relativeAttentionBias(queryLength: T, keyLength: T, offset: offset)
        var finalMask: MLXArray?
        if let mask = mask {
            finalMask = mask + posBias
        } else {
            finalMask = posBias
        }

        var x = x
        var newCache: [(MLXArray, MLXArray)] = []
        for (i, layer) in layers.enumerated() {
            let layerCache = cache.count > i ? cache[i] : nil
            let (out, c) = layer(
                x, memory: memory, mask: finalMask, memoryMask: memoryMask,
                cache: layerCache
            )
            x = out
            newCache.append(c)
        }
        x = ln(x)
        return (x, newCache)
    }
}
