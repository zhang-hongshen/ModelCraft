//
//  WanVAELayers.swift
//  ModelCraft
//
//  Created by Hongshen on 9/4/26.
//

import Foundation
import MLX
import MLXNN

public let cacheT = 2

func createCacheEntry(_ x: MLXArray, existing: MLXArray? = nil) -> MLXArray {
    let t = Int(x.shape[1])
    if t >= cacheT {
        return x[0..., (t - cacheT)..., 0..., 0..., 0...]
    }
    let cacheX = x
    let padT = cacheT - t
    if let existing {
        let oldFramesOffset = max(0, Int(existing.shape[1]) - padT)
        let oldFrames = existing[0..., oldFramesOffset..., 0..., 0..., 0...]
        return MLX.concatenated([oldFrames, cacheX], axis: 1)
    }
    var shape = [x.shape[0], padT]
        shape.append(contentsOf: x.shape[2...])
    let zeros = MLX.zeros(shape).asType(x.dtype)
    return MLX.concatenated([zeros, cacheX], axis: 1)
}

public final class CausalConv3d: Module {
    let stride: (Int, Int, Int)
    let padding: (Int, Int, Int)
    let temporalPad: Int
    let spatialPadH: Int
    let spatialPadW: Int
    var weight: MLXArray
    var bias: MLXArray?

    public init(
        inChannels: Int,
        outChannels: Int,
        kernelSize: (Int, Int, Int),
        stride: (Int, Int, Int) = (1, 1, 1),
        padding: (Int, Int, Int) = (0, 0, 0),
        bias: Bool = true
    ) {
        self.stride = stride
        self.padding = padding
        self.temporalPad = padding.0 * 2
        self.spatialPadH = padding.1
        self.spatialPadW = padding.2
        let scale = 1.0 / sqrt(Float(inChannels * kernelSize.0 * kernelSize.1 * kernelSize.2))
        self.weight = MLXRandom.uniform(
            low: -scale,
            high: scale,
            [outChannels, kernelSize.0, kernelSize.1, kernelSize.2, inChannels]
        )
        self.bias = bias ? MLX.zeros([outChannels]) : nil
    }

    public func callAsFunction(_ xIn: MLXArray, cacheX: MLXArray? = nil) -> MLXArray {
        var x = xIn
        var tPad = temporalPad
        if let cacheX, temporalPad > 0 {
            x = MLX.concatenated([cacheX, x], axis: 1)
            tPad = max(0, temporalPad - cacheX.shape[1])
        }
        if tPad > 0 {
            x = MLX.padded(x, widths: [
                .init(arrayLiteral: 0,0),
                .init(arrayLiteral: tPad,0),
                .init(arrayLiteral: 0,0),
                .init(arrayLiteral: 0,0),
                .init(arrayLiteral: 0,0),])
        }
        if spatialPadH > 0 || spatialPadW > 0 {
            x = MLX.padded(
                x,
                widths: [
                    .init(arrayLiteral:0, 0),
                    .init(arrayLiteral:0, 0),
                    .init(arrayLiteral:spatialPadH, spatialPadH),
                    .init(arrayLiteral:spatialPadW, spatialPadW),
                    .init(arrayLiteral:0, 0)]
            )
        }
        var y = MLX.conv3d(x, weight, stride: .init(stride), padding: 0)
        guard let bias = bias else {
            return y
        }
        return y + bias
    }
}

public final class Resample: Module {
    public enum Mode: String { case upsample2d, upsample3d, downsample2d, downsample3d }
    let mode: Mode
    let upsample: Upsample?
    let conv: Conv2d
    let timeConv: CausalConv3d?

    public init(dim: Int, mode: Mode) {
        self.mode = mode
        switch mode {
        case .upsample2d:
            upsample = Upsample(scaleFactor: [2.0, 2.0], mode: .nearest)
            conv = Conv2d(inputChannels: dim, outputChannels: dim / 2, kernelSize: 3, stride: 1, padding: 0)
            timeConv = nil
        case .upsample3d:
            upsample = Upsample(scaleFactor: [2.0, 2.0], mode: .nearest)
            conv = Conv2d(inputChannels: dim, outputChannels: dim / 2, kernelSize: 3, stride: 1, padding: 0)
            timeConv = CausalConv3d(inChannels: dim, outChannels: dim * 2, kernelSize: (3, 1, 1), padding: (1, 0, 0))
        case .downsample2d:
            upsample = nil
            conv = Conv2d(inputChannels: dim, outputChannels: dim, kernelSize: 3, stride: 2, padding: 0)
            timeConv = nil
        case .downsample3d:
            upsample = nil
            conv = Conv2d(inputChannels: dim, outputChannels: dim, kernelSize: 3, stride: 2, padding: 0)
            timeConv = CausalConv3d(
                inChannels: dim,
                outChannels: dim,
                kernelSize: (3, 1, 1),
                stride: (2, 1, 1),
                padding: (0, 0, 0)
            )
        }
    }

    public func callAsFunction(_ xIn: MLXArray, cache: MLXArray? = nil) -> (MLXArray, MLXArray?) {
        var x = xIn
        let b = Int(x.shape[0]), t = Int(x.shape[1]), h = Int(x.shape[2]), w = Int(x.shape[3]), c = Int(x.shape[4])
        var newCache: MLXArray? = nil

        if mode == .upsample3d {
            if let timeConv {
                if let cache {
                    let cacheInput = x
                    x = timeConv(x, cacheX: cache)
                    newCache = createCacheEntry(cacheInput, existing: cache)
                    x = x.reshaped([b, t, h, w, 2, c]).transposed(0, 1, 4, 2, 3, 5).reshaped([b, t * 2, h, w, c])
                } else {
                    newCache = MLX.zeros([b, cacheT, h, w, c]).asType(x.dtype)
                }
            }
        }

        let tOut = x.shape[1], cOut = x.shape[4]
        x = x.reshaped([b * tOut, x.shape[2], x.shape[3], cOut])

        switch mode {
        case .upsample2d, .upsample3d:
            if let upsample { x = upsample(x) }
            x = MLX.padded(x, widths: [
                .init(arrayLiteral: 0, 0),
                .init(arrayLiteral: 1, 1),
                .init(arrayLiteral: 1, 1),
                .init(arrayLiteral: 0, 0)])
            x = conv(x)
        case .downsample2d, .downsample3d:
            x = MLX.padded(x, widths: [
                .init(arrayLiteral: 0, 0),
                .init(arrayLiteral: 0, 1),
                .init(arrayLiteral: 0, 1),
                .init(arrayLiteral: 0, 0)])
            x = conv(x)
        }

        x = x.reshaped([b, tOut, x.shape[1], x.shape[2], x.shape[3]])

        if mode == .downsample3d, let timeConv {
            if let cache {
                let xWithCache = MLX.concatenated([cache[0..., (cache.shape[1] - 1)..., 0..., 0..., 0...], x], axis: 1)
                newCache = x[0..., (x.shape[1] - 1)..., 0..., 0..., 0...]
                x = timeConv(xWithCache)
            } else {
                newCache = x
            }
        }
        return (x, newCache)
    }
}

public final class ResidualBlock: Module {
    let norm1: RMSNorm
    let conv1: CausalConv3d
    let norm2: RMSNorm
    let conv2: CausalConv3d
    let shortcut: CausalConv3d?

    public init(inDim: Int, outDim: Int) {
        norm1 = RMSNorm(dimensions: inDim, eps: 1e-12)
        conv1 = CausalConv3d(inChannels: inDim, outChannels: outDim, kernelSize: (3, 3, 3), padding: (1, 1, 1))
        norm2 = RMSNorm(dimensions: outDim, eps: 1e-12)
        conv2 = CausalConv3d(inChannels: outDim, outChannels: outDim, kernelSize: (3, 3, 3), padding: (1, 1, 1))
        shortcut = inDim == outDim ? nil : CausalConv3d(inChannels: inDim, outChannels: outDim, kernelSize: (1, 1, 1))
    }

    public func callAsFunction(_ x: MLXArray, cache1: MLXArray?, cache2: MLXArray?) -> (MLXArray, MLXArray, MLXArray) {
        let h = shortcut?(x) ?? x
        var residual = MLXNN.silu(norm1(x))
        let cacheInput1 = residual
        residual = conv1(residual, cacheX: cache1)
        let newCache1 = createCacheEntry(cacheInput1, existing: cache1)

        residual = MLXNN.silu(norm2(residual))
        let cacheInput2 = residual
        residual = conv2(residual, cacheX: cache2)
        let newCache2 = createCacheEntry(cacheInput2, existing: cache2)
        return (h + residual, newCache1, newCache2)
    }
}

public final class AttentionBlock: Module {
    let norm: RMSNorm
    let toQKV: Linear
    let proj: Linear

    public init(dim: Int) {
        norm = RMSNorm(dimensions: dim, eps: 1e-12)
        toQKV = Linear(dim, dim * 3)
        proj = Linear(dim, dim)
    }

    public func callAsFunction(_ xIn: MLXArray) -> MLXArray {
        let identity = xIn
        let b = Int(xIn.shape[0]), t = Int(xIn.shape[1]), h = Int(xIn.shape[2]), w = Int(xIn.shape[3]), c = Int(xIn.shape[4])
        var x = xIn.reshaped([b * t, h, w, c])
        x = norm(x)
        let qkv = toQKV(x).reshaped([b * t, h * w, 3, c])
        let q = qkv[0..., 0..., 0, 0...].reshaped([b * t, 1, h * w, c])
        let k = qkv[0..., 0..., 1, 0...].reshaped([b * t, 1, h * w, c])
        let v = qkv[0..., 0..., 2, 0...].reshaped([b * t, 1, h * w, c])
        
        let attention = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: 1.0 / sqrt(Float(c)), mask: .none)
        let out = proj(attention.squeezed(axis: 1).reshaped([b * t, h, w, c])).reshaped([b, t, h, w, c])
        return out + identity
    }
}
