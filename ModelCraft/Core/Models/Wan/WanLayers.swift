//
//  WanLayers.swift
//  ModelCraft
//
//  Created by Hongshen on 9/4/26.
//

import Foundation
import MLX
import MLXNN


@inline(__always)
func residualGate(_ x: MLXArray, _ y: MLXArray, _ gate: MLXArray) -> MLXArray {
    x + y * gate
}

public final class WanSelfAttention: Module {
    public let dim: Int
    public let numHeads: Int
    public let headDim: Int

    public let qkv: Linear
    public let o: Linear
    public let normQ: RMSNorm
    public let normK: RMSNorm

    public init(dim: Int, numHeads: Int, eps: Float = 1e-6) {
        precondition(dim % numHeads == 0, "dim must be divisible by numHeads")
        self.dim = dim
        self.numHeads = numHeads
        self.headDim = dim / numHeads
        self.qkv = Linear(dim, dim * 3)
        self.o = Linear(dim, dim)
        self.normQ = RMSNorm(dimensions: dim, eps: eps)
        self.normK = RMSNorm(dimensions: dim, eps: eps)
    }

    public func callAsFunction(_ x: MLXArray, gridSizes: [(Int, Int, Int)]) -> MLXArray {
        let b = Int(x.shape[0])
        let l = Int(x.shape[1])
        let c = Int(x.shape[2])

        let qkvOut = qkv(x)
        let parts = MLX.split(qkvOut, parts: 3, axis: -1)
        var q = normQ(parts[0]).reshaped([b, l, numHeads, headDim])
        var k = normK(parts[1]).reshaped([b, l, numHeads, headDim])
        var v = parts[2].reshaped([b, l, numHeads, headDim])

        let g = gridSizes[0]
        q = WanRoPE.apply(q, grid: (g.0, g.1, g.2), headDim: headDim)
        k = WanRoPE.apply(k, grid: (g.0, g.1, g.2), headDim: headDim)

        q = q.transposed(0, 2, 1, 3)
        k = k.transposed(0, 2, 1, 3)
        v = v.transposed(0, 2, 1, 3)

        let attn = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: 1.0 / sqrt(Float(headDim)), mask: nil)
        return o(attn.transposed(0, 2, 1, 3).reshaped([b, l, c]))
    }
}

public class WanCrossAttention: Module {
    public let dim: Int
    public let numHeads: Int
    public let headDim: Int

    public let q: Linear
    public let kv: Linear
    public let o: Linear
    public let normQ: RMSNorm
    public let normK: RMSNorm

    public init(dim: Int, numHeads: Int, eps: Float = 1e-6) {
        precondition(dim % numHeads == 0, "dim must be divisible by numHeads")
        self.dim = dim
        self.numHeads = numHeads
        self.headDim = dim / numHeads
        self.q = Linear(dim, dim)
        self.kv = Linear(dim, dim * 2)
        self.o = Linear(dim, dim)
        self.normQ = RMSNorm(dimensions: dim, eps: eps)
        self.normK = RMSNorm(dimensions: dim, eps: eps)
    }

    public func attend(_ x: MLXArray, _ context: MLXArray) -> (q: MLXArray, out: MLXArray) {
        let b = Int(x.shape[0])
        let l1 = Int(x.shape[1])
        let l2 = Int(context.shape[1])

        let qProj = normQ(q(x)).reshaped([b, l1, numHeads, headDim]).transposed(0, 2, 1, 3)
        let kvProj = kv(context)
        let kvParts = MLX.split(kvProj, parts: 2, axis: -1)
        let kProj = normK(kvParts[0]).reshaped([b, l2, numHeads, headDim]).transposed(0, 2, 1, 3)
        let vProj = kvParts[1].reshaped([b, l2, numHeads, headDim]).transposed(0, 2, 1, 3)
        
        let out = MLXFast.scaledDotProductAttention(
            queries: qProj,
            keys: kProj,
            values: vProj,
            scale: 1.0 / sqrt(Float(headDim)),
            mask: nil
        )
        return (qProj, out)
    }

    public func callAsFunction(_ x: MLXArray, context: MLXArray) -> MLXArray {
        let b = Int(x.shape[0])
        let l1 = Int(x.shape[1])
        let attn = attend(x, context).out
        return o(attn.transposed(0, 2, 1, 3).reshaped([b, l1, dim]))
    }
}

public final class WanI2VCrossAttention: WanCrossAttention {
    public let kImg: Linear
    public let vImg: Linear
    public let normKImg: RMSNorm
    private static let t5ContextTokenNumber = 512
    
    public override init(dim: Int, numHeads: Int, eps: Float = 1e-6) {
        self.kImg = Linear(dim, dim)
        self.vImg = Linear(dim, dim)
        self.normKImg = RMSNorm(dimensions: dim, eps: eps)
        super.init(dim: dim, numHeads: numHeads, eps: eps)
    }

    public override func callAsFunction(_ x: MLXArray, context: MLXArray) -> MLXArray {
        let totalCtx = Int(context.shape[1])
        let imgLen = totalCtx - WanI2VCrossAttention.t5ContextTokenNumber
        
        let imgCtx = context[0..., 0..<imgLen]
        let txtCtx = context[0..., imgLen..<totalCtx]

        let (qLatent, txtOut) = attend(x, txtCtx)
        let b = Int(x.shape[0])
        let l1 = Int(x.shape[1])
        let lImg = Int(imgCtx.shape[1])

        let kImgProj = normKImg(kImg(imgCtx))
            .reshaped([b, lImg, numHeads, headDim])
            .transposed(0, 2, 1, 3)
        let vImgProj = vImg(imgCtx)
            .reshaped([b, lImg, numHeads, headDim])
            .transposed(0, 2, 1, 3)

        let imgOut = MLXFast.scaledDotProductAttention(
            queries: qLatent, keys: kImgProj, values: vImgProj, scale: 1.0 / sqrt(Float(headDim)), mask: nil
        )
        let mixed = (txtOut + imgOut).transposed(0, 2, 1, 3).reshaped([b, l1, dim])
        return o(mixed)
    }
}

public final class WanAttentionBlock: Module {
    public let dim: Int
    public let eps: Float

    public let norm3: LayerNorm?
    public let selfAttn: WanSelfAttention
    public let crossAttn: WanCrossAttention
    public let ffn: Sequential

    public var modulation: MLXArray

    public init(
        dim: Int,
        ffnDim: Int,
        numHeads: Int,
        crossAttnNorm: Bool = false,
        eps: Float = 1e-6,
        crossAttnType: ModelType = .textToVideo
    ) {
        self.dim = dim
        self.eps = eps
        self.norm3 = crossAttnNorm ? LayerNorm(dimensions: dim, eps: eps) : nil
        self.selfAttn = WanSelfAttention(dim: dim, numHeads: numHeads, eps: eps)
        self.crossAttn = (crossAttnType == .textToVideo)
            ? WanI2VCrossAttention(dim: dim, numHeads: numHeads, eps: eps)
            : WanCrossAttention(dim: dim, numHeads: numHeads, eps: eps)
        self.ffn = Sequential(
            layers: Linear(dim, ffnDim),
            GELU(approximation: .tanh),
            Linear(ffnDim, dim)
        )
        self.modulation = MLX.zeros([1, 6, dim])
    }

    public func callAsFunction(
        _ xIn: MLXArray,
        eIn: MLXArray,
        gridSizes: [(Int, Int, Int)],
        context: MLXArray
    ) -> MLXArray {
        var x = xIn
        let e = modulation + eIn

        let xNorm1 = MLXFast.layerNorm(
            x,
            weight: e[0, 1],
            bias: e[0, 0],
            eps: eps
        )
        let y1 = selfAttn(xNorm1, gridSizes: gridSizes)
        x = residualGate(x, y1, e[0..., 2])

        let xNormCross = norm3?(x) ?? x
        x = x + crossAttn(xNormCross, context: context)

        let xNorm2 = MLXFast.layerNorm(
            x,
            weight: e[0, 4],
            bias: e[0, 3],
            eps: eps
        )
        let y2 = ffn(xNorm2)
        x = residualGate(x, y2, e[0..., 5])
        return x
    }
}

public final class Head: Module {
    public let dim: Int
    public let eps: Float
    public let linear: Linear
    public var modulation: MLXArray

    public init(dim: Int, outDim: Int, patchSize: (Int, Int, Int), eps: Float = 1e-6) {
        self.dim = dim
        self.eps = eps
        let outFeatures = patchSize.0 * patchSize.1 * patchSize.2 * outDim
        self.linear = Linear(dim, outFeatures)
        self.modulation = MLX.zeros([1, 2, dim])
    }

    public func callAsFunction(_ x: MLXArray, eIn: MLXArray) -> MLXArray {
        let e = modulation + eIn.expandedDimensions(axis: 1)
        let xNorm = MLXFast.layerNorm(
            x,
            weight: e[0, 1],
            bias: e[0, 0],
            eps: eps
        )
        return linear(xNorm)
    }
}
