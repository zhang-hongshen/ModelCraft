//
//  LTXVideoTransformer.swift
//  ModelCraft
//

import Foundation

import MLX
import MLXFast
import MLXNN

private func ltxSinusoidalEmbedding1D(dim: Int, position: MLXArray) -> MLXArray {
    precondition(dim % 2 == 0, "dim must be even")
    let half = dim / 2
    let p = position.asType(.float32)
    let freq = MLX.exp(-log(10_000.0) * MLX.arange(half, dtype: .float32) / Float(half))
    let sinusoid = p.expandedDimensions(axis: 1) * freq.expandedDimensions(axis: 0)
    return MLX.concatenated([MLX.cos(sinusoid), MLX.sin(sinusoid)], axis: 1).asType(position.dtype)
}

private func ltxApproximateGELU(_ x: MLXArray) -> MLXArray {
    MLXNN.gelu(x)
}

private func ltxApplyRotary(_ x: MLXArray, cos: MLXArray, sin: MLXArray) -> MLXArray {
    let b = Int(x.shape[0])
    let s = Int(x.shape[1])
    let d = Int(x.shape[2])

    let pair = x.reshaped([b, s, d / 2, 2])
    let real = pair[0..., 0..., 0..., 0]
    let imag = pair[0..., 0..., 0..., 1]
    let rotated = MLX.stacked([-imag, real], axis: -1).reshaped([b, s, d])
    return x * cos + rotated * sin
}

public final class LTXVideoAttention: Module {
    public let heads: Int
    public let headDim: Int
    public let queryDimensions: Int
    public let crossAttentionDimensions: Int

    @ModuleInfo(key: "to_q") var toQ: Linear
    @ModuleInfo(key: "to_k") var toK: Linear
    @ModuleInfo(key: "to_v") var toV: Linear
    @ModuleInfo(key: "to_out") var toOut: Linear
    @ModuleInfo(key: "norm_q") var normQ: RMSNorm
    @ModuleInfo(key: "norm_k") var normK: RMSNorm

    public init(
        queryDimensions: Int,
        heads: Int,
        headDim: Int,
        crossAttentionDimensions: Int? = nil
    ) {
        self.heads = heads
        self.headDim = headDim
        self.queryDimensions = queryDimensions
        self.crossAttentionDimensions = crossAttentionDimensions ?? queryDimensions
        let inner = heads * headDim
        self._toQ.wrappedValue = Linear(queryDimensions, inner, bias: true)
        self._toK.wrappedValue = Linear(self.crossAttentionDimensions, inner, bias: true)
        self._toV.wrappedValue = Linear(self.crossAttentionDimensions, inner, bias: true)
        self._toOut.wrappedValue = Linear(inner, queryDimensions, bias: true)
        self._normQ.wrappedValue = RMSNorm(dimensions: inner, eps: 1e-5)
        self._normK.wrappedValue = RMSNorm(dimensions: inner, eps: 1e-5)
    }

    public func callAsFunction(
        hiddenStates: MLXArray,
        encoderHiddenStates: MLXArray? = nil,
        attentionMask: MLXArray? = nil,
        imageRotaryEmbedding: (MLXArray, MLXArray)? = nil
    ) -> MLXArray {
        let context = encoderHiddenStates ?? hiddenStates
        let b = Int(hiddenStates.shape[0])
        let s = Int(hiddenStates.shape[1])
        let contextLength = Int(context.shape[1])

        var q = normQ(toQ(hiddenStates))
        var k = normK(toK(context))

        if let imageRotaryEmbedding {
            q = ltxApplyRotary(q, cos: imageRotaryEmbedding.0, sin: imageRotaryEmbedding.1)
            k = ltxApplyRotary(k, cos: imageRotaryEmbedding.0, sin: imageRotaryEmbedding.1)
        }

        q = q.reshaped([b, s, heads, headDim]).transposed(0, 2, 1, 3)
        k = k.reshaped([b, contextLength, heads, headDim]).transposed(0, 2, 1, 3)
        let v = toV(context)
            .reshaped([b, contextLength, heads, headDim])
            .transposed(0, 2, 1, 3)

        let scale = 1.0 / sqrt(Float(headDim))
        let attended = MLXFast.scaledDotProductAttention(
            queries: q,
            keys: k,
            values: v,
            scale: scale,
            mask: attentionMask
        )
        return toOut(attended.transposed(0, 2, 1, 3).reshaped([b, s, heads * headDim]))
    }
}

public final class LTXVideoRotaryPositionEmbedding {
    let dimensions: Int
    let baseFrameCount: Float = 20
    let baseHeight: Float = 2048
    let baseWidth: Float = 2048
    let theta: Float = 10_000

    public init(dimensions: Int) {
        self.dimensions = dimensions
    }

    public func callAsFunction(
        batchSize: Int,
        frameCount: Int,
        height: Int,
        width: Int,
        interpolationScale: (Float, Float, Float)
    ) -> (MLXArray, MLXArray) {
        let f = MLX.arange(frameCount, dtype: .float32) * interpolationScale.0 / baseFrameCount
        let h = MLX.arange(height, dtype: .float32) * interpolationScale.1 / baseHeight
        let w = MLX.arange(width, dtype: .float32) * interpolationScale.2 / baseWidth

        let gridF = broadcast(
            f.reshaped([frameCount, 1, 1]),
            to: [frameCount, height, width]
        )
        let gridH = broadcast(
            h.reshaped([1, height, 1]),
            to: [frameCount, height, width]
        )
        let gridW = broadcast(
            w.reshaped([1, 1, width]),
            to: [frameCount, height, width]
        )
        let grid = MLX.stacked([gridF, gridH, gridW], axis: -1)
            .reshaped([frameCount * height * width, 3])

        let freqCount = dimensions / 6
        let powers = MLX.linspace(0, 1, count: freqCount).asType(.float32)
        let freqs = MLX.exp(log(theta) * powers) * (Float.pi / 2.0)
        let phases = (grid.expandedDimensions(axis: -1) * 2 - 1) * freqs
        let flat = phases.transposed(0, 2, 1).reshaped([frameCount * height * width, freqCount * 3])
        var cos = repeated(MLX.cos(flat), count: 2, axis: -1)
        var sin = repeated(MLX.sin(flat), count: 2, axis: -1)

        let pad = dimensions - Int(cos.shape[1])
        if pad > 0 {
            cos = MLX.concatenated([MLX.ones([Int(cos.shape[0]), pad]), cos], axis: -1)
            sin = MLX.concatenated([MLX.zeros([Int(sin.shape[0]), pad]), sin], axis: -1)
        }

        cos = broadcast(cos.expandedDimensions(axis: 0), to: [batchSize, Int(cos.shape[0]), Int(cos.shape[1])])
        sin = broadcast(sin.expandedDimensions(axis: 0), to: [batchSize, Int(sin.shape[0]), Int(sin.shape[1])])
        return (cos, sin)
    }
}

public final class LTXVideoPixArtTextProjection: Module {
    @ModuleInfo(key: "linear_1") var linear1: Linear
    @ModuleInfo(key: "linear_2") var linear2: Linear

    public init(inputDimensions: Int, hiddenDimensions: Int, outputDimensions: Int) {
        self._linear1.wrappedValue = Linear(inputDimensions, hiddenDimensions, bias: true)
        self._linear2.wrappedValue = Linear(hiddenDimensions, outputDimensions, bias: true)
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        linear2(ltxApproximateGELU(linear1(x)))
    }
}

public final class LTXVideoTimestepEmbedding: Module {
    @ModuleInfo(key: "linear_1") var linear1: Linear
    @ModuleInfo(key: "linear_2") var linear2: Linear

    public init(inputDimensions: Int = 256, outputDimensions: Int) {
        self._linear1.wrappedValue = Linear(inputDimensions, outputDimensions, bias: true)
        self._linear2.wrappedValue = Linear(outputDimensions, outputDimensions, bias: true)
    }

    public func callAsFunction(_ timestep: MLXArray) -> MLXArray {
        linear2(MLXNN.silu(linear1(ltxSinusoidalEmbedding1D(dim: 256, position: timestep))))
    }
}

public final class LTXVideoAdaLayerNormSingle: Module {
    @ModuleInfo(key: "emb") var embedding: LTXVideoPixArtTimestepEmbedding
    @ModuleInfo(key: "linear") var linear: Linear

    public init(dimensions: Int) {
        self._embedding.wrappedValue = LTXVideoPixArtTimestepEmbedding(dimensions: dimensions)
        self._linear.wrappedValue = Linear(dimensions, dimensions * 6, bias: true)
    }

    public func callAsFunction(_ timestep: MLXArray) -> (MLXArray, MLXArray) {
        let embedded = embedding(timestep)
        return (linear(MLXNN.silu(embedded)), embedded)
    }
}

public final class LTXVideoPixArtTimestepEmbedding: Module {
    @ModuleInfo(key: "timestep_embedder") var timestepEmbedder: LTXVideoTimestepEmbedding

    public init(dimensions: Int) {
        self._timestepEmbedder.wrappedValue = LTXVideoTimestepEmbedding(outputDimensions: dimensions)
    }

    public func callAsFunction(_ timestep: MLXArray) -> MLXArray {
        timestepEmbedder(timestep)
    }
}

public final class LTXVideoFeedForward: Module {
    @ModuleInfo(key: "linear1") var linear1: Linear
    @ModuleInfo(key: "linear2") var linear2: Linear

    public init(dimensions: Int) {
        self._linear1.wrappedValue = Linear(dimensions, dimensions * 4, bias: true)
        self._linear2.wrappedValue = Linear(dimensions * 4, dimensions, bias: true)
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        linear2(ltxApproximateGELU(linear1(x)))
    }
}

public final class LTXVideoTransformerBlock: Module {
    public let dimensions: Int

    @ModuleInfo var norm1: RMSNorm
    @ModuleInfo var norm2: RMSNorm
    @ModuleInfo var attn1: LTXVideoAttention
    @ModuleInfo var attn2: LTXVideoAttention
    @ModuleInfo var ff: LTXVideoFeedForward
    public var scaleShiftTable: MLXArray

    public init(
        dimensions: Int,
        attentionHeads: Int,
        attentionHeadDimensions: Int,
        crossAttentionDimensions: Int
    ) {
        self.dimensions = dimensions
        self._norm1.wrappedValue = RMSNorm(dimensions: dimensions, eps: 1e-6)
        self._norm2.wrappedValue = RMSNorm(dimensions: dimensions, eps: 1e-6)
        self._attn1.wrappedValue = LTXVideoAttention(
            queryDimensions: dimensions,
            heads: attentionHeads,
            headDim: attentionHeadDimensions
        )
        self._attn2.wrappedValue = LTXVideoAttention(
            queryDimensions: dimensions,
            heads: attentionHeads,
            headDim: attentionHeadDimensions,
            crossAttentionDimensions: crossAttentionDimensions
        )
        self._ff.wrappedValue = LTXVideoFeedForward(dimensions: dimensions)
        self.scaleShiftTable = MLXRandom.normal([6, dimensions]) / sqrt(Float(dimensions))
    }

    public func callAsFunction(
        hiddenStates input: MLXArray,
        encoderHiddenStates: MLXArray,
        temb: MLXArray,
        imageRotaryEmbedding: (MLXArray, MLXArray),
        encoderAttentionMask: MLXArray?
    ) -> MLXArray {
        let batch = Int(input.shape[0])
        var x = input
        let ada = scaleShiftTable.expandedDimensions(axis: 0).expandedDimensions(axis: 0)
            + temb.reshaped([batch, -1, 6, dimensions])

        let shiftMSA = ada[0..., 0..., 0, 0...]
        let scaleMSA = ada[0..., 0..., 1, 0...]
        let gateMSA = ada[0..., 0..., 2, 0...]
        let shiftMLP = ada[0..., 0..., 3, 0...]
        let scaleMLP = ada[0..., 0..., 4, 0...]
        let gateMLP = ada[0..., 0..., 5, 0...]

        var y = norm1(x)
        y = y * (1 + scaleMSA) + shiftMSA
        y = attn1(
            hiddenStates: y,
            imageRotaryEmbedding: imageRotaryEmbedding
        )
        x = x + y * gateMSA

        y = attn2(
            hiddenStates: x,
            encoderHiddenStates: encoderHiddenStates,
            attentionMask: encoderAttentionMask
        )
        x = x + y

        y = norm2(x)
        y = y * (1 + scaleMLP) + shiftMLP
        y = ff(y)
        x = x + y * gateMLP
        return x
    }
}

public final class LTXVideoTransformer3DModel: Module {
    public let configuration: LTXVideoTransformerConfiguration
    public let innerDimensions: Int
    public let rope: LTXVideoRotaryPositionEmbedding

    @ModuleInfo(key: "proj_in") var projIn: Linear
    @ModuleInfo(key: "time_embed") var timeEmbed: LTXVideoAdaLayerNormSingle
    @ModuleInfo(key: "caption_projection") var captionProjection: LTXVideoPixArtTextProjection
    @ModuleInfo(key: "transformer_blocks") var transformerBlocks: [LTXVideoTransformerBlock]
    @ModuleInfo(key: "norm_out") var normOut: LayerNorm
    @ModuleInfo(key: "proj_out") var projOut: Linear
    public var scaleShiftTable: MLXArray

    public init(configuration: LTXVideoTransformerConfiguration) {
        let innerDimensions = configuration.numAttentionHeads * configuration.attentionHeadDim
        self.configuration = configuration
        self.innerDimensions = innerDimensions
        self.rope = LTXVideoRotaryPositionEmbedding(dimensions: innerDimensions)
        self._projIn.wrappedValue = Linear(configuration.inChannels, innerDimensions, bias: true)
        self._timeEmbed.wrappedValue = LTXVideoAdaLayerNormSingle(dimensions: innerDimensions)
        self._captionProjection.wrappedValue = LTXVideoPixArtTextProjection(
            inputDimensions: configuration.captionChannels,
            hiddenDimensions: innerDimensions,
            outputDimensions: configuration.crossAttentionDim
        )
        self._transformerBlocks.wrappedValue = (0..<configuration.numLayers).map { _ in
            LTXVideoTransformerBlock(
                dimensions: innerDimensions,
                attentionHeads: configuration.numAttentionHeads,
                attentionHeadDimensions: configuration.attentionHeadDim,
                crossAttentionDimensions: configuration.crossAttentionDim
            )
        }
        self._normOut.wrappedValue = LayerNorm(dimensions: innerDimensions, eps: 1e-6)
        self._projOut.wrappedValue = Linear(innerDimensions, configuration.outChannels, bias: true)
        self.scaleShiftTable = MLXRandom.normal([2, innerDimensions]) / sqrt(Float(innerDimensions))
    }

    public func callAsFunction(
        hiddenStates: MLXArray,
        encoderHiddenStates: MLXArray,
        timestep: MLXArray,
        encoderAttentionMask: MLXArray?,
        frameCount: Int,
        height: Int,
        width: Int,
        ropeInterpolationScale: (Float, Float, Float)
    ) -> MLXArray {
        let batch = Int(hiddenStates.shape[0])
        let imageRotaryEmbedding = rope(
            batchSize: batch,
            frameCount: frameCount,
            height: height,
            width: width,
            interpolationScale: ropeInterpolationScale
        )

        var x = projIn(hiddenStates)
        let (temb, embeddedTimestep) = timeEmbed(timestep)
        var context = captionProjection(encoderHiddenStates)

        if let encoderAttentionMask {
            let mask = (1 - encoderAttentionMask.asType(x.dtype)) * -10_000
            context = context * encoderAttentionMask.expandedDimensions(axis: -1).asType(context.dtype)
            for block in transformerBlocks {
                x = block(
                    hiddenStates: x,
                    encoderHiddenStates: context,
                    temb: temb.reshaped([batch, 1, -1]),
                    imageRotaryEmbedding: imageRotaryEmbedding,
                    encoderAttentionMask: mask.expandedDimensions(axis: 1).expandedDimensions(axis: 1)
                )
            }
        } else {
            for block in transformerBlocks {
                x = block(
                    hiddenStates: x,
                    encoderHiddenStates: context,
                    temb: temb.reshaped([batch, 1, -1]),
                    imageRotaryEmbedding: imageRotaryEmbedding,
                    encoderAttentionMask: nil
                )
            }
        }

        let scaleShift = scaleShiftTable.expandedDimensions(axis: 0).expandedDimensions(axis: 0)
            + embeddedTimestep.reshaped([batch, -1, 1, innerDimensions])
        let shift = scaleShift[0..., 0..., 0, 0...]
        let scale = scaleShift[0..., 0..., 1, 0...]
        x = normOut(x)
        x = x * (1 + scale) + shift
        return projOut(x)
    }

    public static func sanitize(_ weights: [String: MLXArray]) -> [String: MLXArray] {
        var result: [String: MLXArray] = [:]
        for (key, valueIn) in weights {
            var key = key
            var value = valueIn
            if key.hasPrefix("transformer.") {
                key.removeFirst("transformer.".count)
            }
            if key.hasPrefix("model.diffusion_model.") {
                key.removeFirst("model.diffusion_model.".count)
            }
            key = key.replacingOccurrences(of: "to_out.0.", with: "to_out.")
            key = key.replacingOccurrences(of: ".ff.net.0.proj.", with: ".ff.linear1.")
            key = key.replacingOccurrences(of: ".ff.net.2.", with: ".ff.linear2.")
            key = key.replacingOccurrences(of: ".scale_shift_table", with: ".scaleShiftTable")
            if key == "scale_shift_table" {
                key = "scaleShiftTable"
            }

            if key.hasSuffix(".weight"), Int(value.ndim) == 5 {
                value = value.transposed(0, 2, 3, 4, 1)
            }
            result[key] = value
        }
        return result
    }
}
