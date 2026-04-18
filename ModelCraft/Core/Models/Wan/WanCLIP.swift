//
//  WanCLIP.swift
//  ModelCraft
//
//  Created by Hongshen on 9/4/26.
//

import Foundation
import MLX
import MLXNN
import ImageIO
import CoreGraphics

public final class CLIPAttentionBlock: Module {
    let norm1: LayerNorm
    let selfAttn: CLIPSelfAttention
    let norm2: LayerNorm
    let mlp: CLIPMLP

    public init(dim: Int = 1280, numHeads: Int = 16, mlpRatio: Int = 4) {
        norm1 = LayerNorm(dimensions: dim)
        selfAttn = CLIPSelfAttention(dim: dim, numHeads: numHeads)
        norm2 = LayerNorm(dimensions: dim)
        mlp = CLIPMLP(dim: dim, midDim: dim * mlpRatio)
    }

    public func callAsFunction(_ xIn: MLXArray) -> MLXArray {
        var x = xIn
        x = x + selfAttn(norm1(x))
        x = x + mlp(norm2(x))
        return x
    }
}

public final class CLIPSelfAttention: Module {
    let numHeads: Int
    let headDim: Int
    let qProj: Linear
    let kProj: Linear
    let vProj: Linear
    let outProj: Linear

    public init(dim: Int, numHeads: Int) {
        self.numHeads = numHeads
        self.headDim = dim / numHeads
        self.qProj = Linear(dim, dim)
        self.kProj = Linear(dim, dim)
        self.vProj = Linear(dim, dim)
        self.outProj = Linear(dim, dim)
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        let b = Int(x.shape[0]), l = Int(x.shape[1])
        var q = qProj(x).reshaped([b, l, numHeads, headDim]).transposed(0, 2, 1, 3)
        let k = kProj(x).reshaped([b, l, numHeads, headDim]).transposed(0, 2, 1, 3)
        let v = vProj(x).reshaped([b, l, numHeads, headDim]).transposed(0, 2, 1, 3)
        q = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale:  1.0 / sqrt(Float(headDim)), mask: nil)
        q = q.transposed(0, 2, 1, 3).reshaped([b, l, numHeads * headDim])
        return outProj(q)
    }
}

public final class CLIPMLP: Module {
    let fc1: Linear
    let fc2: Linear
    
    init(dim: Int, midDim: Int) {
        fc1 = Linear(dim, midDim)
        fc2 = Linear(midDim, dim)
    }
    
    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        fc2(MLXNN.gelu(fc1(x)))
    }
}

public final class CLIPVisionEncoder: Module {
    let numPatches: Int
    let dim: Int
    let numLayers: Int
    let patchEmbedding: Conv2d
    var clsEmbedding: MLXArray
    var positionEmbedding: MLXArray
    let preNorm: LayerNorm
    let blocks: [CLIPAttentionBlock]

    public init(
        imageSize: Int = 224,
        patchSize: Int = 14,
        dim: Int = 1280,
        numHeads: Int = 16,
        numLayers: Int = 32,
        mlpRatio: Int = 4
    ) {
        self.numPatches = (imageSize / patchSize) * (imageSize / patchSize)
        self.dim = dim
        self.numLayers = numLayers
        self.patchEmbedding = Conv2d(
            inputChannels: 3,
            outputChannels: dim,
            kernelSize: IntOrPair(patchSize),
            stride: IntOrPair(patchSize),
            bias: false
        )
        self.clsEmbedding = MLX.zeros([1, 1, dim])
        self.positionEmbedding = MLX.zeros([1, numPatches + 1, dim])
        self.preNorm = LayerNorm(dimensions: dim)
        self.blocks = (0..<numLayers).map { _ in
            CLIPAttentionBlock(dim: dim, numHeads: numHeads, mlpRatio: mlpRatio)
        }
    }

    public func callAsFunction(_ xIn: MLXArray) -> MLXArray {
        let b = Int(xIn.shape[0])
        var x = patchEmbedding(xIn).reshaped([b, numPatches, dim])
        let cls = broadcast(clsEmbedding, to: [b, 1, dim])
        x = concatenated([cls, x], axis: 1)
        x = preNorm(x + positionEmbedding)
        for i in 0..<(numLayers - 1) {
            x = blocks[i](x)
        }
        return x
    }

    public static func sanitize(_ weights: [String: MLXArray]) -> [String: MLXArray] {
        var remapped: [String: MLXArray] = [:]

        for (key, valueIn) in weights {
            guard key.hasPrefix("visual.") else { continue }
            if key.contains("post_norm") || key.contains("ln_post") || key == "visual.head" {
                continue
            }

            var value = valueIn

            if key == "visual.conv1.weight" || key == "visual.patch_embedding.weight" {
                if Int(value.ndim) == 4 {
                    value = value.transposed(0, 2, 3, 1)
                }
                remapped["patch_embedding.weight"] = value
                continue
            }

            if key == "visual.class_embedding" || key == "visual.cls_embedding" {
                remapped["cls_embedding"] = value.reshaped([1, 1, Int(value.shape[0])])
                continue
            }

            if key == "visual.positional_embedding" || key == "visual.pos_embedding" {
                if Int(value.ndim) == 2 {
                    value = value.reshaped([1, Int(value.shape[0]), Int(value.shape[1])])
                }
                remapped["position_embedding"] = value
                continue
            }

            if key.hasPrefix("visual.ln_pre.") || key.hasPrefix("visual.pre_norm.") {
                let param = String(key.split(separator: ".").last ?? "")
                remapped["pre_norm.\(param)"] = value
                continue
            }

            let openClipPrefix = "visual.transformer.resblocks."
            let hfPrefix = "visual.transformer."
            let blockBody: String
            if key.hasPrefix(openClipPrefix) {
                blockBody = String(key.dropFirst(openClipPrefix.count))
            } else if key.hasPrefix(hfPrefix) {
                blockBody = String(key.dropFirst(hfPrefix.count))
            } else {
                continue
            }

            let parts = blockBody.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2, Int(parts[0]) != nil else { continue }
            let block = parts[0]
            let rest = parts[1]
            let blockPrefix = "block_\(block)"

            if rest == "attn.in_proj_weight" || rest == "attn.to_qkv.weight" {
                let d = Int(value.shape[0]) / 3
                let q = value[0..<d, 0...]
                let k = value[d..<(2 * d), 0...]
                let v = value[(2 * d)..<Int(value.shape[0]), 0...]
                remapped["\(blockPrefix).self_attn.q_proj.weight"] = q
                remapped["\(blockPrefix).self_attn.k_proj.weight"] = k
                remapped["\(blockPrefix).self_attn.v_proj.weight"] = v
                continue
            }

            if rest == "attn.in_proj_bias" || rest == "attn.to_qkv.bias" {
                let d = Int(value.shape[0]) / 3
                let q = value[0..<d]
                let k = value[d..<(2 * d)]
                let v = value[(2 * d)..<Int(value.shape[0])]
                remapped["\(blockPrefix).self_attn.q_proj.bias"] = q
                remapped["\(blockPrefix).self_attn.k_proj.bias"] = k
                remapped["\(blockPrefix).self_attn.v_proj.bias"] = v
                continue
            }

            if rest.hasPrefix("attn.out_proj.") || rest.hasPrefix("attn.proj.") {
                let param = String(rest.split(separator: ".").last ?? "")
                remapped["\(blockPrefix).self_attn.out_proj.\(param)"] = value
                continue
            }

            if rest.hasPrefix("ln_1.") || rest.hasPrefix("norm1.") {
                let param = String(rest.split(separator: ".").last ?? "")
                remapped["\(blockPrefix).norm1.\(param)"] = value
                continue
            }

            if rest.hasPrefix("ln_2.") || rest.hasPrefix("norm2.") {
                let param = String(rest.split(separator: ".").last ?? "")
                remapped["\(blockPrefix).norm2.\(param)"] = value
                continue
            }

            if rest.hasPrefix("mlp.c_fc.") || rest.hasPrefix("mlp.0.") {
                let param = String(rest.split(separator: ".").last ?? "")
                remapped["\(blockPrefix).mlp.fc1.\(param)"] = value
                continue
            }

            if rest.hasPrefix("mlp.c_proj.") || rest.hasPrefix("mlp.2.") {
                let param = String(rest.split(separator: ".").last ?? "")
                remapped["\(blockPrefix).mlp.fc2.\(param)"] = value
                continue
            }
        }

        return remapped
    }
}

public enum CLIPImagePreprocess {
    public static func preprocess(imageURL: URL) throws -> MLXArray {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "WanCLIP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load image"])
        }

        let width = 224
        let height = 224
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw NSError(domain: "WanCLIP", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGContext"])
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let pixelData = context.data else {
            throw NSError(domain: "WanCLIP", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to get pixel data"])
        }

        let ptr = pixelData.assumingMemoryBound(to: UInt8.self)
        let totalPixels = width * height
        var rawRGB = [UInt8]()
        rawRGB.reserveCapacity(totalPixels * 3)
    
        for i in 0..<totalPixels {
            let src = i * 4
            rawRGB.append(ptr[src])     // R
            rawRGB.append(ptr[src + 1]) // G
            rawRGB.append(ptr[src + 2]) // B
        }

        let mean = MLXArray([0.48145466, 0.4578275, 0.40821073], [1, 1, 1, 3])
        let std = MLXArray([0.26862954, 0.26130258, 0.27577711], [1, 1, 1, 3])

        let pixels = MLXArray(rawRGB, [1, height, width, 3])

        return (pixels.asType(.float32) / 255.0 - mean) / std
    }
}
