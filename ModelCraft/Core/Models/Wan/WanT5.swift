//
//  WanT5.swift
//  ModelCraft
//
//  Created by Hongshen on 9/4/26.
//

import Foundation
import MLX
import MLXNN

public final class T5RelativeEmbedding: Module {
    let numBuckets: Int
    let numHeads: Int
    let bidirectional: Bool
    let maxDist: Int
    let embedding: Embedding

    public init(numBuckets: Int, numHeads: Int, bidirectional: Bool = true, maxDist: Int = 128) {
        self.numBuckets = numBuckets
        self.numHeads = numHeads
        self.bidirectional = bidirectional
        self.maxDist = maxDist
        self.embedding = Embedding(embeddingCount: numBuckets, dimensions: numHeads)
    }

    private func relativeBucket(_ relPos: MLXArray) -> MLXArray {
        let nBuckets = bidirectional ? numBuckets / 2 : numBuckets
        var relBuckets = bidirectional
            ? (relPos .> MLXArray(0)).asType(.int32) * MLXArray(Int32(nBuckets))
            : MLX.zeros(like: relPos).asType(.int32)
        var rp = bidirectional ? MLX.abs(relPos) : -MLX.minimum(relPos, MLX.zeros(like: relPos))

        let maxExact = nBuckets / 2
        let isSmall = rp .< MLXArray(maxExact)
        let scale = Float(nBuckets - maxExact) / log(Float(maxDist) / Float(maxExact))
        var rpLarge = maxExact + (MLX.log(rp.asType(.float32) / Float(maxExact)) * scale).asType(.int32)
        rpLarge = MLX.minimum(rpLarge, MLXArray(nBuckets - 1))
        relBuckets = relBuckets + MLX.where(isSmall, rp, rpLarge)
        return relBuckets
    }

    public func callAsFunction(_ lq: Int, _ lk: Int) -> MLXArray {
        let q = MLX.arange(lq).expandedDimensions(axis: 1)
        let k = MLX.arange(lk).expandedDimensions(axis: 0)
        let rel = k - q
        let buckets = relativeBucket(rel)
        let pos = embedding(buckets)
        return pos.transposed(2, 0, 1).expandedDimensions(axis: 0)
    }
}

public final class T5Attention: Module {
    let numHeads: Int
    let headDim: Int
    let q: Linear
    let k: Linear
    let v: Linear
    let o: Linear

    public init(dim: Int, dimAttn: Int, numHeads: Int) {
        self.numHeads = numHeads
        self.headDim = dimAttn / numHeads
        self.q = Linear(dim, dimAttn, bias: false)
        self.k = Linear(dim, dimAttn, bias: false)
        self.v = Linear(dim, dimAttn, bias: false)
        self.o = Linear(dimAttn, dim, bias: false)
    }

    public func callAsFunction(
        _ x: MLXArray,
        context: MLXArray? = nil,
        mask: MLXArray? = nil,
        posBias: MLXArray? = nil
    ) -> MLXArray {
        let ctx = context ?? x
        let b = Int(x.shape[0]), sx = Int(x.shape[1]), sk = Int(ctx.shape[1])
        var qProj = q(x).reshaped([b, sx, numHeads, headDim]).transposed(0, 2, 1, 3)
        let kProj = k(ctx).reshaped([b, sk, numHeads, headDim]).transposed(0, 2, 1, 3)
        let vProj = v(ctx).reshaped([b, sk, numHeads, headDim]).transposed(0, 2, 1, 3)
        
        var attnBias = MLX.zeros([b, numHeads, sx, sk]).asType(x.dtype)
        if let posBias { attnBias = attnBias + posBias }
        if let mask {
            // mask shape expected [B,S] or [B,S,S]
            var m = mask
            if Int(mask.ndim) == 2 {
                m = mask.expandedDimensions(axes: [1, 2])
            } else {
                m = mask.expandedDimensions(axis: 1)
            }
            attnBias = MLX.where(m .== MLXArray(0), MLXArray(-1e9), attnBias)
        }

        let out = MLXFast.scaledDotProductAttention(queries: qProj, keys: kProj, values: vProj, scale: 1.0, mask: attnBias)
        qProj = out.transposed(0, 2, 1, 3).reshaped([b, sx, numHeads * headDim])
        return o(qProj)
    }
}

public final class T5FeedForward: Module {
    let gate: Linear
    let fc1: Linear
    let fc2: Linear

    public init(dim: Int, dimFFN: Int) {
        gate = Linear(dim, dimFFN, bias: false)
        fc1 = Linear(dim, dimFFN, bias: false)
        fc2 = Linear(dimFFN, dim, bias: false)
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        fc2(fc1(x) * MLXNN.geluApproximate(gate(x)))
    }
}

public final class T5SelfAttentionBlock: Module {
    let sharedPos: Bool
    let norm1: RMSNorm
    let attn: T5Attention
    let norm2: RMSNorm
    let ffn: T5FeedForward
    let posEmbedding: T5RelativeEmbedding?

    public init(
        dim: Int,
        dimAttn: Int,
        dimFFN: Int,
        numHeads: Int,
        numBuckets: Int,
        sharedPos: Bool = true
    ) {
        self.sharedPos = sharedPos
        self.norm1 = RMSNorm(dimensions: dim, eps: 1e-6)
        self.attn = T5Attention(dim: dim, dimAttn: dimAttn, numHeads: numHeads)
        self.norm2 = RMSNorm(dimensions: dim, eps: 1e-6)
        self.ffn = T5FeedForward(dim: dim, dimFFN: dimFFN)
        self.posEmbedding = sharedPos ? nil : T5RelativeEmbedding(
            numBuckets: numBuckets,
            numHeads: numHeads,
            bidirectional: true
        )
    }

    public func callAsFunction(_ xIn: MLXArray, mask: MLXArray? = nil, posBias: MLXArray? = nil) -> MLXArray {
        var x = xIn
        var e: MLXArray? {
            guard let posEmbedding = posEmbedding else {
                return posBias
            }
            return posEmbedding(x.shape[1], x.shape[1])
        }
        x = x + attn(norm1(x), mask: mask, posBias: e)
        x = x + ffn(norm2(x))
        return x
    }
}

public final class T5Encoder: Module {
    let dim: Int
    let numLayers: Int
    let sharedPos: Bool
    let tokenEmbedding: Embedding
    let posEmbedding: T5RelativeEmbedding?
    let blocks: [T5SelfAttentionBlock]
    let norm: RMSNorm

    public init(
        vocabSize: Int,
        dim: Int,
        dimAttn: Int,
        dimFFN: Int,
        numHeads: Int,
        numLayers: Int,
        numBuckets: Int,
        sharedPos: Bool = true
    ) {
        self.dim = dim
        self.numLayers = numLayers
        self.sharedPos = sharedPos
        self.tokenEmbedding = Embedding(embeddingCount: vocabSize, dimensions: dim)
        self.posEmbedding = sharedPos
            ? T5RelativeEmbedding(numBuckets: numBuckets, numHeads: numHeads, bidirectional: true)
            : nil
        self.blocks = (0..<numLayers).map { _ in
            T5SelfAttentionBlock(
                dim: dim,
                dimAttn: dimAttn,
                dimFFN: dimFFN,
                numHeads: numHeads,
                numBuckets: numBuckets,
                sharedPos: sharedPos
            )
        }
        self.norm = RMSNorm(dimensions: dim, eps: 1e-6)
    }

    public func callAsFunction(_ ids: MLXArray, mask: MLXArray? = nil) -> MLXArray {
        var x = tokenEmbedding(ids)
        let seqLen = x.shape[1]
        var e: MLXArray? {
            guard let posEmbedding = posEmbedding else {
                return nil
            }
            return posEmbedding(seqLen, seqLen)
        }
        for b in blocks {
            x = b(x, mask: mask, posBias: e)
        }
        return norm(x)
    }

    public static func sanitizeKey(_ key: String) -> String? {
        var k = key
        if k.hasPrefix("model.") { k.removeFirst("model.".count) }
        if k.contains("ffn.gate.1") || k.contains("dropout") { return nil }
        k = k.replacingOccurrences(of: "ffn.gate.0.", with: "ffn.gate.")
        return k
    }

    public static func sanitize(_ weights: [String: MLXArray]) -> [String: MLXArray] {
        var remapped: [String: MLXArray] = [:]
        for (key, value) in weights {
            guard let newKey = sanitizeKey(key) else { continue }
            remapped[newKey] = value
        }
        return remapped
    }
}

public func createUMT5XXLEncoder() -> T5Encoder {
    T5Encoder(
        vocabSize: 256_384,
        dim: 4096,
        dimAttn: 4096,
        dimFFN: 10_240,
        numHeads: 64,
        numLayers: 24,
        numBuckets: 32,
        sharedPos: false
    )
}
