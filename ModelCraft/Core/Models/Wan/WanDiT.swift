//
//  WanDiT.swift
//  ModelCraft
//
//  Created by Hongshen on 9/4/26.
//

import Foundation
import MLX
import MLXNN
import Hub

public func sinusoidalEmbedding1D(dim: Int, position: MLXArray) -> MLXArray {
    precondition(dim % 2 == 0, "dim must be even")
    let half = dim / 2
    let p = position.asType(.float32)
    let freq = MLX.exp(-log(10_000.0) * MLX.arange(half, dtype: .float32) / Float(half))
    let sinusoid = p.expandedDimensions(axis: 1) * freq.expandedDimensions(axis: 0)
    return MLX.concatenated([MLX.cos(sinusoid), MLX.sin(sinusoid)], axis: 1).asType(position.dtype)
}

public enum ModelType: String, Sendable, Codable {
    case textToVideo, imageToVideo
}

public final class WanDiT: Module {
    public let modelType: ModelType
    public let patchSize: (Int, Int, Int)
    public let dim: Int
    public let freqDim: Int

    public let patchEmbedding: Conv3d
    public let textEmbedding: Sequential
    public let timeEmbedding: Sequential
    public let timeProjection: Sequential

    // i2v-only
    public let imgEmbNorm1: LayerNorm?
    public let imgEmbLinear1: Linear?
    public let imgEmbLinear2: Linear?
    public let imgEmbNorm2: LayerNorm?

    public var blocks: [WanAttentionBlock]
    public let head: Head

    public init(
        modelType: ModelType = .textToVideo,
        patchSize: (Int, Int, Int) = (1, 2, 2),
        inDim: Int = 16,
        dim: Int = 2048,
        ffnDim: Int = 8192,
        freqDim: Int = 256,
        textDim: Int = 4096,
        outDim: Int = 16,
        numHeads: Int = 16,
        numLayers: Int = 32,
        crossAttnNorm: Bool = true,
        eps: Float = 1e-6
    ) {
        self.modelType = modelType
        self.patchSize = patchSize
        self.dim = dim
        self.freqDim = freqDim

        self.patchEmbedding = Conv3d(
            inputChannels: inDim,
            outputChannels: dim,
            kernelSize: [patchSize.0, patchSize.1, patchSize.2],
            stride: [patchSize.0, patchSize.1, patchSize.2],
            bias: true
        )
        self.textEmbedding = Sequential(
            layers: Linear(textDim, dim),
            GELU(approximation: .tanh),
            Linear(dim, dim)
        )
        self.timeEmbedding = Sequential(
            layers: Linear(freqDim, dim),
            SiLU(),
            Linear(dim, dim)
        )
        self.timeProjection = Sequential(layers: SiLU(), Linear(dim, 6 * dim))

        if modelType == .imageToVideo {
            let clipDim = 1280
            self.imgEmbNorm1 = LayerNorm(dimensions: clipDim, eps: eps)
            self.imgEmbLinear1 = Linear(clipDim, clipDim)
            self.imgEmbLinear2 = Linear(clipDim, dim)
            self.imgEmbNorm2 = LayerNorm(dimensions: dim, eps: eps)
        } else {
            self.imgEmbNorm1 = nil
            self.imgEmbLinear1 = nil
            self.imgEmbLinear2 = nil
            self.imgEmbNorm2 = nil
        }

        self.blocks = (0..<numLayers).map { _ in
            WanAttentionBlock(
                dim: dim,
                ffnDim: ffnDim,
                numHeads: numHeads,
                crossAttnNorm: crossAttnNorm,
                eps: eps,
                crossAttnType: modelType
            )
        }
        self.head = Head(dim: dim, outDim: outDim, patchSize: patchSize, eps: eps)
    }

    public func embedImage(_ clipFea: MLXArray) -> MLXArray {
        guard let n1 = imgEmbNorm1, let l1 = imgEmbLinear1, let l2 = imgEmbLinear2, let n2 = imgEmbNorm2 else {
            return clipFea
        }
        var x = n1(clipFea)
        x = l1(x)
        x = MLXNN.gelu(x)
        x = l2(x)
        x = n2(x)
        return x
    }

    public func computeTimeEmbedding(_ t: MLXArray) -> (tEmb: MLXArray, e0: MLXArray) {
        let e = sinusoidalEmbedding1D(dim: freqDim, position: t)
        let tEmb = timeEmbedding(e)
        let e0 = timeProjection(tEmb)
        return (tEmb, e0)
    }

    public func callAsFunction(
        _ xIn: MLXArray,
        t: MLXArray,
        context: MLXArray,
        blockResidual: MLXArray? = nil,
        precomputedTime: (MLXArray, MLXArray)? = nil,
        clipFea: MLXArray? = nil,
        firstFrame: MLXArray? = nil
    ) -> (output: MLXArray, residual: MLXArray) {
        var x = xIn
        if let firstFrame {
            x = MLX.concatenated([x, firstFrame], axis: -1)
        }

        // Patchify: [F,H,W,C] -> [1,Fp,Hp,Wp,dim] -> [1, Fp*Hp*Wp, dim]
        x = patchEmbedding(x.expandedDimensions(axis: 0))
        let fp = Int(x.shape[1])
        let hp = Int(x.shape[2])
        let wp = Int(x.shape[3])
        let grid = [(fp, hp, wp)]
        x = x.reshaped([1, fp * hp * wp, dim])

        var ctx = textEmbedding(context.expandedDimensions(axis: 0))
        if let clipFea {
            let clipProj = embedImage(clipFea)
            ctx = MLX.concatenated([clipProj, ctx], axis: 1)
        }

        let tEmb: MLXArray
        let eProj: MLXArray
        if let p = precomputedTime {
            tEmb = p.0
            eProj = p.1
        } else {
            let e = sinusoidalEmbedding1D(dim: freqDim, position: t)
            tEmb = timeEmbedding(e)
            eProj = timeProjection(tEmb)
        }
        let e = eProj.reshaped([1, 6, dim])

        let residual: MLXArray
        if let blockResidual {
            x = x + blockResidual
            residual = blockResidual
        } else {
            let xInBlocks = x
            for block in blocks {
                x = block(x, eIn: e, gridSizes: grid, context: ctx)
            }
            residual = x - xInBlocks
        }

        x = head(x, eIn: tEmb)

        // Unpatchify
        let pt = patchSize.0
        let ph = patchSize.1
        let pw = patchSize.2
        let c = Int(x.shape[2]) / (pt * ph * pw)
        let out = x[0, 0..., 0...]
            .reshaped([fp, hp, wp, pt, ph, pw, c])
            .transposed(0, 3, 1, 4, 2, 5, 6)
            .reshaped([fp * pt, hp * ph, wp * pw, c])

        return (out, residual)
    }

    /// Python `sanitize` equivalent for checkpoint key remapping.
    /// Returns remapped key-value pairs.
    public static func sanitizeKey(_ key: String) -> String? {
        if key.contains("weight_scale") { return nil }
        var newKey = key
        if newKey.hasPrefix("model.") {
            newKey.removeFirst("model.".count)
        }
        newKey = newKey.replacingOccurrences(of: "ffn.0.", with: "ffn.layers.0.")
        newKey = newKey.replacingOccurrences(of: "ffn.2.", with: "ffn.layers.2.")
        newKey = newKey.replacingOccurrences(of: "text_embedding.0.", with: "text_embedding.layers.0.")
        newKey = newKey.replacingOccurrences(of: "text_embedding.2.", with: "text_embedding.layers.2.")
        newKey = newKey.replacingOccurrences(of: "time_embedding.0.", with: "time_embedding.layers.0.")
        newKey = newKey.replacingOccurrences(of: "time_embedding.2.", with: "time_embedding.layers.2.")
        newKey = newKey.replacingOccurrences(of: "time_projection.1.", with: "time_projection.layers.1.")
        newKey = newKey.replacingOccurrences(of: "head.head.", with: "head.linear.")
        newKey = newKey.replacingOccurrences(of: "img_emb.proj.0.", with: "img_emb_norm1.")
        newKey = newKey.replacingOccurrences(of: "img_emb.proj.1.", with: "img_emb_linear1.")
        newKey = newKey.replacingOccurrences(of: "img_emb.proj.3.", with: "img_emb_linear2.")
        newKey = newKey.replacingOccurrences(of: "img_emb.proj.4.", with: "img_emb_norm2.")
        return newKey
    }

    public static func sanitize(_ weights: [String: MLXArray]) -> [String: MLXArray] {
        var remapped: [String: MLXArray] = [:]
        for (key, valueIn) in weights {
            guard let newKey = sanitizeKey(key) else { continue }
            var value = valueIn

            // PyTorch Conv3d [O, I, kT, kH, kW] -> MLX Conv3d [O, kT, kH, kW, I]
            if newKey.contains("patch_embedding"), newKey.hasSuffix("weight"), Int(value.ndim) == 5 {
                value = value.transposed(0, 2, 3, 4, 1)
            }
            remapped[newKey] = value
        }

        var merged = mergeQKVWeights(remapped)

        // Fold +1 into scale modulation slots to match forward path.
        for (key, value) in merged where key.hasSuffix(".modulation") {
            if Int(value.shape[1]) == 6 {
                let offset = MLXArray([Float32(0), 1, 0, 0, 1, 0]).reshaped([1, 6, 1])
                merged[key] = value + offset
            } else if Int(value.shape[1]) == 2 {
                let offset = MLXArray([Float32(0), 1]).reshaped([1, 2, 1])
                merged[key] = value + offset
            }
        }

        return merged
    }

    private static func mergeQKVWeights(_ weights: [String: MLXArray]) -> [String: MLXArray] {
        var merged: [String: MLXArray] = [:]
        var consumed = Set<String>()

        for key in weights.keys {
            let comps = key.split(separator: ".").map(String.init)
            if comps.count == 5,
                comps[0] == "blocks",
                comps[2] == "self_attn",
                comps[3] == "q",
                (comps[4] == "weight" || comps[4] == "bias")
            {
                let prefix = "blocks.\(comps[1]).self_attn"
                let param = comps[4]
                let qKey = "\(prefix).q.\(param)"
                let kKey = "\(prefix).k.\(param)"
                let vKey = "\(prefix).v.\(param)"
                if let q = weights[qKey], let k = weights[kKey], let v = weights[vKey] {
                    merged["\(prefix).qkv.\(param)"] = MLX.concatenated([q, k, v], axis: 0)
                    consumed.insert(qKey)
                    consumed.insert(kKey)
                    consumed.insert(vKey)
                }
                continue
            }

            if comps.count == 5,
                comps[0] == "blocks",
                comps[2] == "cross_attn",
                comps[3] == "k",
                (comps[4] == "weight" || comps[4] == "bias")
            {
                let prefix = "blocks.\(comps[1]).cross_attn"
                let param = comps[4]
                let kKey = "\(prefix).k.\(param)"
                let vKey = "\(prefix).v.\(param)"
                if let k = weights[kKey], let v = weights[vKey] {
                    merged["\(prefix).kv.\(param)"] = MLX.concatenated([k, v], axis: 0)
                    consumed.insert(kKey)
                    consumed.insert(vKey)
                }
                continue
            }
        }

        for (key, value) in weights where !consumed.contains(key) {
            merged[key] = value
        }
        return merged
    }
}
