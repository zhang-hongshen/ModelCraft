//
//  WanVAE.swift
//  ModelCraft
//
//  Created by Hongshen on 9/4/26.
//

import Foundation
import MLX
import MLXNN

public final class Decoder3d: Module {
    let conv1: CausalConv3d
    let middleRes1: ResidualBlock
    let middleAttn: AttentionBlock
    let middleRes2: ResidualBlock
    let upsampleStages: [[Any]]
    let headNorm: RMSNorm
    let headConv: CausalConv3d
    public let numCacheSlots: Int

    public init(
        dim: Int = 96,
        zDim: Int = 16,
        dimMult: [Int] = [1, 2, 4, 4],
        numResBlocks: Int = 2,
        temporalUpsample: [Bool] = [true, true, false]
    ) {
        let dims = ([dimMult.last ?? 4] + dimMult.reversed()).map { dim * $0 }
        conv1 = CausalConv3d(inChannels: zDim, outChannels: dims[0], kernelSize: (3, 3, 3), padding: (1, 1, 1))
        middleRes1 = ResidualBlock(inDim: dims[0], outDim: dims[0])
        middleAttn = AttentionBlock(dim: dims[0])
        middleRes2 = ResidualBlock(inDim: dims[0], outDim: dims[0])

        var stages: [[Any]] = []
        var scale: Float = 1.0 / pow(2.0, Float(dimMult.count - 2))
        for (i, pair) in zip(0..<(dims.count - 1), zip(dims.dropLast(), dims.dropFirst())) {
            var inDim = pair.0
            let outDim = pair.1
            if i == 1 || i == 2 || i == 3 { inDim /= 2 }
            var stage: [Any] = []
            for _ in 0..<(numResBlocks + 1) {
                stage.append(ResidualBlock(inDim: inDim, outDim: outDim))
                inDim = outDim
            }
            if i != dimMult.count - 1 {
                let mode: Resample.Mode = temporalUpsample[i] ? .upsample3d : .upsample2d
                stage.append(Resample(dim: outDim, mode: mode))
                scale *= 2.0
            }
            _ = scale
            stages.append(stage)
        }
        upsampleStages = stages
        headNorm = RMSNorm(dimensions: dims.last ?? dim, eps: 1e-12)
        headConv = CausalConv3d(inChannels: dims.last ?? dim, outChannels: 3, kernelSize: (3, 3, 3), padding: (1, 1, 1))

        var n = 1 + 2 + 2
        for stage in stages {
            for layer in stage {
                if layer is ResidualBlock { n += 2 }
                else if layer is Resample { n += 1 }
            }
        }
        n += 1
        numCacheSlots = n
    }

    public func callAsFunction(_ xIn: MLXArray, featCache: [MLXArray?]) -> (MLXArray, [MLXArray?]) {
        var x = xIn
        var cacheIdx = 0
        var outCache: [MLXArray?] = []

        let cacheInput1 = x
        x = conv1(x, cacheX: featCache[cacheIdx]); outCache.append(createCacheEntry(cacheInput1, existing: featCache[cacheIdx])); cacheIdx += 1
        var r = middleRes1(x, cache1: featCache[cacheIdx], cache2: featCache[cacheIdx + 1]); x = r.0; outCache += [r.1, r.2]; cacheIdx += 2
        x = middleAttn(x)
        r = middleRes2(x, cache1: featCache[cacheIdx], cache2: featCache[cacheIdx + 1]); x = r.0; outCache += [r.1, r.2]; cacheIdx += 2

        for stage in upsampleStages {
            for layer in stage {
                if let rb = layer as? ResidualBlock {
                    let rr = rb(x, cache1: featCache[cacheIdx], cache2: featCache[cacheIdx + 1])
                    x = rr.0; outCache += [rr.1, rr.2]; cacheIdx += 2
                } else if let attn = layer as? AttentionBlock {
                    x = attn(x)
                } else if let rs = layer as? Resample {
                    let rr = rs(x, cache: featCache[cacheIdx]); x = rr.0
                    if let c = rr.1 { outCache.append(c); cacheIdx += 1 }
                }
            }
        }

        x = MLXNN.silu(headNorm(x))
        let cacheInputHead = x
        x = headConv(x, cacheX: featCache[cacheIdx]); outCache.append(createCacheEntry(cacheInputHead, existing: featCache[cacheIdx]))
        return (x, outCache)
    }
}

public final class Encoder3d: Module {
    let conv1: CausalConv3d
    let downsampleStages: [[Any]]
    let middleRes1: ResidualBlock
    let middleAttn: AttentionBlock
    let middleRes2: ResidualBlock
    let headNorm: RMSNorm
    let headConv: CausalConv3d
    public let numCacheSlots: Int

    public init(
        dim: Int = 96,
        zDim: Int = 16,
        dimMult: [Int] = [1, 2, 4, 4],
        numResBlocks: Int = 2,
        temporalDownsample: [Bool] = [false, true, true]
    ) {
        let dims = ([1] + dimMult).map { dim * $0 }
        conv1 = CausalConv3d(inChannels: 3, outChannels: dims[0], kernelSize: (3, 3, 3), padding: (1, 1, 1))

        var stages: [[Any]] = []
        for (i, pair) in zip(0..<(dims.count - 1), zip(dims.dropLast(), dims.dropFirst())) {
            var inDim = pair.0
            let outDim = pair.1
            var stage: [Any] = []
            for _ in 0..<numResBlocks {
                stage.append(ResidualBlock(inDim: inDim, outDim: outDim))
                inDim = outDim
            }
            if i != dimMult.count - 1 {
                stage.append(Resample(dim: outDim, mode: temporalDownsample[i] ? .downsample3d : .downsample2d))
            }
            stages.append(stage)
        }
        downsampleStages = stages
        middleRes1 = ResidualBlock(inDim: dims.last ?? dim, outDim: dims.last ?? dim)
        middleAttn = AttentionBlock(dim: dims.last ?? dim)
        middleRes2 = ResidualBlock(inDim: dims.last ?? dim, outDim: dims.last ?? dim)
        headNorm = RMSNorm(dimensions: dims.last ?? dim, eps: 1e-12)
        headConv = CausalConv3d(inChannels: dims.last ?? dim, outChannels: zDim * 2, kernelSize: (3, 3, 3), padding: (1, 1, 1))

        var n = 1
        for stage in stages {
            for layer in stage {
                if layer is ResidualBlock { n += 2 }
                else if layer is Resample { n += 1 }
            }
        }
        n += 2 + 2 + 1
        numCacheSlots = n
    }

    public func callAsFunction(_ xIn: MLXArray, featCache: [MLXArray?]) -> (MLXArray, [MLXArray?]) {
        var x = xIn
        var cacheIdx = 0
        var outCache: [MLXArray?] = []
        let cIn = x
        x = conv1(x, cacheX: featCache[cacheIdx]); outCache.append(createCacheEntry(cIn, existing: featCache[cacheIdx])); cacheIdx += 1

        for stage in downsampleStages {
            for layer in stage {
                if let rb = layer as? ResidualBlock {
                    let rr = rb(x, cache1: featCache[cacheIdx], cache2: featCache[cacheIdx + 1])
                    x = rr.0; outCache += [rr.1, rr.2]; cacheIdx += 2
                } else if let attn = layer as? AttentionBlock {
                    x = attn(x)
                } else if let rs = layer as? Resample {
                    let rr = rs(x, cache: featCache[cacheIdx]); x = rr.0
                    if let c = rr.1 { outCache.append(c); cacheIdx += 1 }
                }
            }
        }

        var r = middleRes1(x, cache1: featCache[cacheIdx], cache2: featCache[cacheIdx + 1]); x = r.0; outCache += [r.1, r.2]; cacheIdx += 2
        x = middleAttn(x)
        r = middleRes2(x, cache1: featCache[cacheIdx], cache2: featCache[cacheIdx + 1]); x = r.0; outCache += [r.1, r.2]; cacheIdx += 2
        x = MLXNN.silu(headNorm(x))
        let cHead = x
        x = headConv(x, cacheX: featCache[cacheIdx]); outCache.append(createCacheEntry(cHead, existing: featCache[cacheIdx]))
        return (x, outCache)
    }
}

public final class WanVAE: Module {
    let encoder: Encoder3d
    let conv1: CausalConv3d
    let decoder: Decoder3d
    let conv2: CausalConv3d
    let mean: MLXArray
    let std: MLXArray
    let zDim = 16

    public override init() {
        encoder = Encoder3d()
        conv1 = CausalConv3d(inChannels: 32, outChannels: 32, kernelSize: (1, 1, 1))
        decoder = Decoder3d()
        conv2 = CausalConv3d(inChannels: 16, outChannels: 16, kernelSize: (1, 1, 1))
        mean = MLXArray([
            -0.7571, -0.7089, -0.9113, 0.1075, -0.1745, 0.9653, -0.1517, 1.5508,
            0.4134, -0.0715, 0.5517, -0.3632, -0.1922, -0.9497, 0.2503, -0.2921,
        ]).asType(.float32)
        std = MLXArray([
            2.8184, 1.4541, 2.3275, 2.6558, 1.2196, 1.7708, 2.6052, 2.0743,
            3.2687, 2.1526, 2.8652, 1.5579, 1.6382, 1.1253, 2.8251, 1.9160,
        ] as [Float32])
        super.init()
    }

    public func decode(_ zIn: MLXArray) -> MLXArray {
        var z = zIn.reshaped([1, Int(zIn.shape[0]), Int(zIn.shape[1]), Int(zIn.shape[2]), Int(zIn.shape[3])])
        let scale = MLXArray(1.0) / std
        z = z / scale.reshaped([1, 1, 1, 1, zDim]) + mean.reshaped([1, 1, 1, 1, zDim])
        var x = conv2(z)
        let numFrames = Int(x.shape[1])
        var featCache: [MLXArray?] = Array(repeating: nil, count: decoder.numCacheSlots)
        var outputs: [MLXArray] = []
        for i in 0..<numFrames {
            let frame = x[0..., i..<(i + 1), 0..., 0..., 0...]
            let out = decoder(frame, featCache: featCache)
            outputs.append(out.0)
            featCache = out.1
        }
        let out = MLX.clip(MLX.concatenated(outputs, axis: 1), min: MLXArray(-1.0), max: MLXArray(1.0))
        return out[0, 0..., 0..., 0..., 0...]
    }

    public func encode(_ xIn: MLXArray) -> MLXArray {
        let x = xIn.reshaped([1, Int(xIn.shape[0]), Int(xIn.shape[1]), Int(xIn.shape[2]), Int(xIn.shape[3])])
        let numFrames = Int(x.shape[1])
        var featCache: [MLXArray?] = Array(repeating: nil, count: encoder.numCacheSlots)
        var outputs: [MLXArray] = []
        var i = 0
        var chunkIdx = 0
        while i < numFrames {
            let step = chunkIdx == 0 ? 1 : 4
            let end = min(numFrames, i + step)
            let chunk = x[0..., i..<end, 0..., 0..., 0...]
            let out = encoder(chunk, featCache: featCache)
            outputs.append(out.0)
            featCache = out.1
            i = end
            chunkIdx += 1
        }
        var out = MLX.concatenated(outputs, axis: 1)
        out = conv1(out)
        var mu = out[0..., 0..., 0..., 0..., 0..<zDim]
        let scale = MLXArray(1.0) / std
        mu = (mu - mean.reshaped([1, 1, 1, 1, zDim])) * scale.reshaped([1, 1, 1, 1, zDim])
        return mu[0, 0..., 0..., 0..., 0...]
    }

    public static func sanitize(_ weights: [String: MLXArray]) -> [String: MLXArray] {
        var remapped: [String: MLXArray] = [:]
        for (key, valueIn) in weights {
            var newKey = key
            var value = valueIn

            if newKey.contains("weight") {
                if Int(value.ndim) == 5 {
                    value = value.transposed(0, 2, 3, 4, 1)
                } else if Int(value.ndim) == 4 {
                    value = value.transposed(0, 2, 3, 1)
                }
            }

            newKey = newKey.replacingOccurrences(of: ".gamma", with: ".weight")
            newKey = newKey.replacingOccurrences(of: "decoder.middle.0.", with: "decoder.middle_res1.")
            newKey = newKey.replacingOccurrences(of: "decoder.middle.1.", with: "decoder.middle_attn.")
            newKey = newKey.replacingOccurrences(of: "decoder.middle.2.", with: "decoder.middle_res2.")
            newKey = newKey.replacingOccurrences(of: "decoder.head.0.", with: "decoder.head_norm.")
            newKey = newKey.replacingOccurrences(of: "decoder.head.2.", with: "decoder.head_conv.")
            newKey = newKey.replacingOccurrences(of: "encoder.middle.0.", with: "encoder.middle_res1.")
            newKey = newKey.replacingOccurrences(of: "encoder.middle.1.", with: "encoder.middle_attn.")
            newKey = newKey.replacingOccurrences(of: "encoder.middle.2.", with: "encoder.middle_res2.")
            newKey = newKey.replacingOccurrences(of: "encoder.head.0.", with: "encoder.head_norm.")
            newKey = newKey.replacingOccurrences(of: "encoder.head.2.", with: "encoder.head_conv.")

            if newKey.hasPrefix("decoder.upsamples.") {
                newKey = mapVAEUpsampleKey(newKey)
            }
            if newKey.hasPrefix("encoder.downsamples.") {
                newKey = mapVAEDownsampleKey(newKey)
            }

            newKey = newKey.replacingOccurrences(of: ".residual.0.", with: ".norm1.")
            newKey = newKey.replacingOccurrences(of: ".residual.2.", with: ".conv1.")
            newKey = newKey.replacingOccurrences(of: ".residual.3.", with: ".norm2.")
            newKey = newKey.replacingOccurrences(of: ".residual.6.", with: ".conv2.")
            newKey = newKey.replacingOccurrences(of: ".resample.1.", with: ".conv.")

            if (newKey.contains("to_qkv") || newKey.contains("proj")) && newKey.contains("weight") {
                if Int(value.ndim) == 4, Int(value.shape[1]) == 1, Int(value.shape[2]) == 1 {
                    value = value.reshaped([Int(value.shape[0]), Int(value.shape[3])])
                }
            }

            if newKey.contains("norm") && newKey.contains("weight") && Int(value.ndim) > 1 {
                value = value.squeezed()
            }

            remapped[newKey] = value
        }
        return remapped
    }

    private static func mapVAEUpsampleKey(_ key: String) -> String {
        let prefix = "decoder.upsamples."
        guard key.hasPrefix(prefix) else { return key }
        let body = String(key.dropFirst(prefix.count))
        let parts = body.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let layerIdx = Int(parts[0]) else { return key }
        let rest = parts[1]

        let stageSizes = [4, 4, 4, 3]  // (num_res_blocks+2)x3 + last (num_res_blocks+1)
        var stage = 0
        var localIdx = layerIdx
        for (s, size) in stageSizes.enumerated() {
            if localIdx < size {
                stage = s
                break
            }
            localIdx -= size
        }
        return "decoder.upsamples.\(stage).\(localIdx).\(rest)"
    }

    private static func mapVAEDownsampleKey(_ key: String) -> String {
        let prefix = "encoder.downsamples."
        guard key.hasPrefix(prefix) else { return key }
        let body = String(key.dropFirst(prefix.count))
        let parts = body.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let layerIdx = Int(parts[0]) else { return key }
        let rest = parts[1]

        let stageSizes = [3, 3, 3, 2]  // (num_res_blocks+1)x3 + last num_res_blocks
        var stage = 0
        var localIdx = layerIdx
        for (s, size) in stageSizes.enumerated() {
            if localIdx < size {
                stage = s
                break
            }
            localIdx -= size
        }
        return "encoder.downsamples.\(stage).\(localIdx).\(rest)"
    }
}
