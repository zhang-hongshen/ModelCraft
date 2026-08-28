// SPDX-License-Identifier: Apache-2.0

import Foundation
import Hub
import MLX
import MLXNN

struct Snake1d {
    /// Stored **raw**, not in log scale — that is `SnakeBeta`, which is the
    /// decoder's activation. `Snake1d` uses alpha directly and passes it as
    /// beta as well, so the two are the same tensor.
    let alpha: MLXArray

    init(alpha: MLXArray) {
        self.alpha = alpha
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        // The model export stores [1, C, 1]; NLC wants [1, 1, C].
        let a = alpha.reshaped([1, 1, alpha.size])
        return snake(x, alpha: a, beta: a)
    }
}

/// `Snake1d -> Conv1d(k=7, dilation=d) -> Snake1d -> Conv1d(k=1)`, plus residual.
///
/// The dilation is the whole point of the unit — the three units in a block run
/// at 1, 3 and 9, which is what gives the encoder its receptive field. Running
/// them all at dilation 1 leaves every shape correct.
struct AudioResidualUnit {
    let act1: Snake1d
    let conv1: VaeConv1d
    let act2: Snake1d
    let conv2: VaeConv1d

    init(dilation: Int, prefix: String, weights: [String: MLXArray]) throws {
        func get(_ n: String) throws -> MLXArray {
            guard let a = weights[n] else { throw H3BaseWeights.Error.missing(n) }
            return a
        }
        self.act1 = Snake1d(alpha: try get(prefix + "block.0.alpha"))
        self.conv1 = VaeConv1d(weight: try get(prefix + "block.1.weight").transposed(0, 2, 1),
                               bias: try get(prefix + "block.1.bias"),
                               stride: 1, padding: ((7 - 1) * dilation) / 2, dilation: dilation)
        self.act2 = Snake1d(alpha: try get(prefix + "block.2.alpha"))
        self.conv2 = VaeConv1d(weight: try get(prefix + "block.3.weight").transposed(0, 2, 1),
                               bias: try get(prefix + "block.3.bias"),
                               stride: 1, padding: 0, dilation: 1)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let y = conv2(act2(conv1(act1(x))))
        // The reference centre-crops the residual when the block shortens it.
        // With padding = 3*dilation the lengths match, so this is a guard, not
        // a code path — but it is the reference's guard.
        let pad = (x.dim(1) - y.dim(1)) / 2
        let skip = pad > 0 ? x[0..., pad ..< (x.dim(1) - pad), 0...] : x
        return y + skip
    }
}

/// Three residual units at dilation 1/3/9, then a strided downsample.
struct AudioEncoderBlock {
    let units: [AudioResidualUnit]
    let act: Snake1d
    let down: VaeConv1d

    init(stride: Int, prefix: String, weights: [String: MLXArray]) throws {
        func get(_ n: String) throws -> MLXArray {
            guard let a = weights[n] else { throw H3BaseWeights.Error.missing(n) }
            return a
        }
        self.units = try [1, 3, 9].enumerated().map { i, d in
            try AudioResidualUnit(dilation: d, prefix: prefix + "block.\(i).", weights: weights)
        }
        self.act = Snake1d(alpha: try get(prefix + "block.3.alpha"))
        // kernel is 2*stride and padding is ceil(stride/2) — NOT (kernel-stride)/2,
        // which agrees for even strides and is wrong by one for stride 5.
        self.down = VaeConv1d(weight: try get(prefix + "block.4.weight").transposed(0, 2, 1),
                              bias: try get(prefix + "block.4.bias"),
                              stride: stride, padding: (stride + 1) / 2, dilation: 1)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = x
        for u in units { h = u(h) }
        return down(act(h))
    }
}

/// Causal attention that also pools 2048 channels down to the 32-wide latent.
///
/// The pooling is `adaptive_avg_pool1d(mean_over_heads(attn), 32)`. With 8 heads
/// the head dim is 256, and 256/32 = 8, so it is a mean over consecutive groups
/// of 8. Dropping the pool and picking a head count that happens to make the
/// head dim 32 gives the right shape and the wrong values.
struct AudioCausalAttention {
    let qkv: MLXArray
    let qkvBias: MLXArray
    let proj: MLXArray
    let projBias: MLXArray
    let heads: Int
    let headDim: Int
    let outDim: Int

    init(inDim: Int, outDim: Int, heads: Int, prefix: String,
         weights: [String: MLXArray]) throws {
        func get(_ n: String) throws -> MLXArray {
            guard let a = weights[n] else { throw H3BaseWeights.Error.missing(n) }
            return a
        }
        self.heads = heads
        self.headDim = inDim / heads
        self.outDim = outDim
        self.qkv = try get(prefix + "qkv.weight")
        // q_bias | zero_k_bias | v_bias — the k half is a registered buffer of
        // zeros, present so the concatenation has the right width.
        self.qkvBias = concatenated([try get(prefix + "q_bias"),
                                     try get(prefix + "zero_k_bias"),
                                     try get(prefix + "v_bias")], axis: 0)
        self.proj = try get(prefix + "proj.weight")
        self.projBias = try get(prefix + "proj.bias")
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let b = x.dim(0), n = x.dim(1)
        let f = matmul(x, qkv.T) + qkvBias
        let parts = f.reshaped([b, n, 3, heads, headDim]).transposed(2, 0, 3, 1, 4)
        let q = parts[0], k = parts[1], v = parts[2]

        let mask = MLXArray(0 ..< n).reshaped([n, 1]) .>= MLXArray(0 ..< n).reshaped([1, n])
        let o = MLXFast.scaledDotProductAttention(
            queries: q, keys: k, values: v,
            scale: 1.0 / Float(headDim).squareRoot(), mask: mask)

        // mean over heads, then adaptive average pool headDim -> outDim
        let pooled = o.mean(axis: 1)                                  // [B, N, headDim]
        precondition(headDim % outDim == 0,
                     "adaptive pool \(headDim) -> \(outDim) is not an integer ratio")
        let group = headDim / outDim
        let down = pooled.reshaped([b, n, outDim, group]).mean(axis: -1)
        return matmul(down, proj.T) + projBias
    }
}

/// `w2(gelu_tanh(w0(x)) * w1(x))` — note which branch is activated.
struct AudioGeGluMlp {
    let norm: VaeLayerNorm
    let w0: MLXArray, w0b: MLXArray
    let w1: MLXArray, w1b: MLXArray
    let w2: MLXArray, w2b: MLXArray

    init(prefix: String, weights: [String: MLXArray]) throws {
        func get(_ n: String) throws -> MLXArray {
            guard let a = weights[n] else { throw H3BaseWeights.Error.missing(n) }
            return a
        }
        self.norm = VaeLayerNorm(weight: try get(prefix + "norm.weight"),
                                 bias: try get(prefix + "norm.bias"))
        self.w0 = try get(prefix + "w0.weight"); self.w0b = try get(prefix + "w0.bias")
        self.w1 = try get(prefix + "w1.weight"); self.w1b = try get(prefix + "w1.bias")
        self.w2 = try get(prefix + "w2.weight"); self.w2b = try get(prefix + "w2.bias")
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let h = norm(x)
        // GELU is the tanh approximation in the reference, not the exact erf form.
        let a = geluApproximate(matmul(h, w0.T) + w0b)
        let b = matmul(h, w1.T) + w1b
        return matmul(a * b, w2.T) + w2b
    }
}

/// The encoder's posterior head: attention and a linear projection in parallel,
/// summed, then a GeGLU residual.
struct AudioAttnProjection {
    let norm1: VaeLayerNorm
    let norm2: VaeLayerNorm
    let norm3: VaeLayerNorm
    let attn: AudioCausalAttention
    let proj: MLXArray
    let projBias: MLXArray
    let mlp: AudioGeGluMlp

    init(inDim: Int, outDim: Int, heads: Int, prefix: String,
         weights: [String: MLXArray]) throws {
        func get(_ n: String) throws -> MLXArray {
            guard let a = weights[n] else { throw H3BaseWeights.Error.missing(n) }
            return a
        }
        self.norm1 = VaeLayerNorm(weight: try get(prefix + "norm1.weight"),
                                  bias: try get(prefix + "norm1.bias"))
        self.norm2 = VaeLayerNorm(weight: try get(prefix + "norm2.weight"),
                                  bias: try get(prefix + "norm2.bias"))
        self.norm3 = VaeLayerNorm(weight: try get(prefix + "norm3.weight"),
                                  bias: try get(prefix + "norm3.bias"))
        self.attn = try AudioCausalAttention(inDim: inDim, outDim: outDim, heads: heads,
                                             prefix: prefix + "attn.", weights: weights)
        self.proj = try get(prefix + "proj.weight")
        self.projBias = try get(prefix + "proj.bias")
        self.mlp = try AudioGeGluMlp(prefix: prefix + "mlp.", weights: weights)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let h = matmul(norm3(x), proj.T) + projBias + attn(norm1(x))
        return h + mlp(norm2(h))
    }
}

final class H3AudioVAEEncoder {
    /// 2 * 4 * 4 * 5 * 5 — audio samples per latent frame.
    static let hopLength = 800
    static let strides = [2, 4, 4, 5, 5]
    static let latentChannels = 32

    let convIn: VaeConv1d
    let blocks: [AudioEncoderBlock]
    let actOut: Snake1d
    let convOut: VaeConv1d
    let preBlock: AudioAttnProjection
    let meanProj: MLXArray
    let meanProjBias: MLXArray
    let latentsMean: MLXArray
    let latentsStd: MLXArray

    init(weights: [String: MLXArray]) throws {
        func get(_ n: String) throws -> MLXArray {
            guard let a = weights[n] else { throw H3BaseWeights.Error.missing(n) }
            return a
        }
        self.latentsMean = try get("latents_mean")
        self.latentsStd = try get("latents_std")

        self.convIn = VaeConv1d(weight: try get("encoder.block.0.weight").transposed(0, 2, 1),
                                bias: try get("encoder.block.0.bias"),
                                stride: 1, padding: 3, dilation: 1)
        self.blocks = try Self.strides.enumerated().map { i, s in
            try AudioEncoderBlock(stride: s, prefix: "encoder.block.\(i + 1).", weights: weights)
        }
        self.actOut = Snake1d(alpha: try get("encoder.block.6.alpha"))
        self.convOut = VaeConv1d(weight: try get("encoder.block.7.weight").transposed(0, 2, 1),
                                 bias: try get("encoder.block.7.bias"),
                                 stride: 1, padding: 1, dilation: 1)

        // 8 heads, not 64 — the head dim is what the adaptive pool consumes.
        self.preBlock = try AudioAttnProjection(inDim: 2048, outDim: Self.latentChannels,
                                                heads: 8, prefix: "pre_block.",
                                                weights: weights)
        // Conv1d(32, 32, kernel 1) is a matmul in disguise.
        self.meanProj = try get("mean_proj.weight").reshaped([Self.latentChannels,
                                                              Self.latentChannels])
        self.meanProjBias = try get("mean_proj.bias")
        // `logs_proj` is deliberately not loaded: encode returns the mean.
    }

    convenience init(hub: HubApi, configuration: H3Configuration) throws {
        try self.init(
            weights: try H3Loader.loadWeights(
                hub: hub,
                configuration: configuration,
                key: "audioVAEWeights"))
    }

    /// Stereo waveform `[B, 2, L]` in [-1, 1] -> normalized latents `[B, 32, 2, T]`.
    func encode(_ waveform: MLXArray) -> MLXArray {
        let b = waveform.dim(0), s = waveform.dim(1), l = waveform.dim(2)
        let padded = (l + Self.hopLength - 1) / Self.hopLength * Self.hopLength
        var w = waveform
        if padded > l {
            w = concatenated([w, MLXArray.zeros([b, s, padded - l], dtype: w.dtype)], axis: -1)
        }
        // stereo channels run through the mono encoder independently
        var x = w.reshaped([b * s, 1, padded]).transposed(0, 2, 1)   // [B*S, L, 1]

        x = convIn(x)
        for blk in blocks {
            x = blk(x)
        }
        x = actOut(x)
        x = convOut(x)                                               // [B*S, T, 2048]

        let n1 = preBlock.norm1(x)
        let attention = preBlock.attn(n1)
        let branch = matmul(preBlock.norm3(x), preBlock.proj.T) + preBlock.projBias
                   + attention
        x = branch + preBlock.mlp(preBlock.norm2(branch))             // [B*S, T, 32]

        let z = matmul(x, meanProj.T) + meanProjBias
        let zn = (z - latentsMean.reshaped([1, 1, Self.latentChannels]))
               / latentsStd.reshaped([1, 1, Self.latentChannels])

        let t = zn.dim(1)
        return zn.transposed(0, 2, 1)                                // [B*S, 32, T]
                 .reshaped([b, s, Self.latentChannels, t])
                 .transposed(0, 2, 1, 3)                             // [B, 32, 2, T]
    }
}

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Kammerich


func snake(_ x: MLXArray, alpha: MLXArray, beta: MLXArray) -> MLXArray {
    let t = sin(alpha * x)
    return (t * t) / (beta + 1e-9) + x
}

struct VaeConv1d {
    let weight: MLXArray
    let bias: MLXArray?
    let stride: Int
    let padding: Int
    let dilation: Int
    let groups: Int

    init(weight: MLXArray, bias: MLXArray? = nil, stride: Int = 1, padding: Int = 0, dilation: Int = 1, groups: Int = 1) {
        self.weight = weight
        self.bias = bias
        self.stride = stride
        self.padding = padding
        self.dilation = dilation
        self.groups = groups
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var out = conv1d(x, weight, stride: stride, padding: padding, dilation: dilation, groups: groups)
        if let bias {
            out = out + bias.reshaped([1, 1, bias.dim(0)])
        }
        return out
    }
}

struct VaeConvTransposed1d {
    let weight: MLXArray
    let bias: MLXArray?
    let stride: Int
    let padding: Int
    let dilation: Int
    let groups: Int

    init(weight: MLXArray, bias: MLXArray? = nil, stride: Int = 1, padding: Int = 0, dilation: Int = 1, groups: Int = 1) {
        self.weight = weight
        self.bias = bias
        self.stride = stride
        self.padding = padding
        self.dilation = dilation
        self.groups = groups
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var out = convTransposed1d(x, weight, stride: stride, padding: padding, dilation: dilation, groups: groups)
        if let bias {
            out = out + bias.reshaped([1, 1, bias.dim(0)])
        }
        return out
    }
}

class SnakeBeta: Module {
    let alpha: MLXArray
    let beta: MLXArray

    init(alpha: MLXArray, beta: MLXArray) {
        self.alpha = alpha
        self.beta = beta
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let a = exp(alpha).reshaped([1, 1, alpha.dim(0)])
        let b = exp(beta).reshaped([1, 1, beta.dim(0)])
        return snake(x, alpha: a, beta: b)
    }
}

class UpSample1d: Module {
    let ratio: Int
    let stride: Int
    let pad: Int
    let padLeft: Int
    let padRight: Int
    let filter: MLXArray

    init(ratio: Int = 2, kernelSize: Int = 12, filter: MLXArray) {
        self.ratio = ratio
        self.stride = ratio
        self.pad = kernelSize / ratio - 1
        self.padLeft = self.pad * ratio + (kernelSize - ratio) / 2
        self.padRight = self.pad * ratio + (kernelSize - ratio + 1) / 2
        self.filter = filter
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let padWidths: [IntOrPair] = [
            0,
            [pad, pad],
            0
        ]
        let paddedX = padded(x, widths: padWidths, mode: .edge)

        let C = x.dim(2)
        let weight = broadcast(filter, to: [C, filter.dim(1), filter.dim(2)]).transposed(0, 2, 1)

        var out = convTransposed1d(paddedX, weight.asType(x.dtype), stride: stride, padding: 0, groups: C)
        out = out * Float(ratio)

        let s = padLeft
        let e = out.dim(1) - padRight
        let indices: [any MLXArrayIndex] = [0 ..< out.dim(0), s ..< e, 0 ..< out.dim(2)]
        return out[indices]
    }
}

class LowPassFilter1d: Module {
    let padLeft: Int
    let padRight: Int
    let stride: Int
    let filter: MLXArray

    init(cutoff: Float = 0.5, halfWidth: Float = 0.6, stride: Int = 1, kernelSize: Int = 12, filter: MLXArray) {
        self.padLeft = kernelSize / 2 - (kernelSize % 2 == 0 ? 1 : 0)
        self.padRight = kernelSize / 2
        self.stride = stride
        self.filter = filter
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let padWidths: [IntOrPair] = [
            0,
            [padLeft, padRight],
            0
        ]
        let paddedX = padded(x, widths: padWidths, mode: .edge)

        let C = x.dim(2)
        let weight = broadcast(filter, to: [C, filter.dim(1), filter.dim(2)]).transposed(0, 2, 1)

        return conv1d(paddedX, weight.asType(x.dtype), stride: stride, padding: 0, groups: C)
    }
}

class DownSample1d: Module {
    let lowpass: LowPassFilter1d

    init(ratio: Int = 2, kernelSize: Int = 12, filter: MLXArray) {
        self.lowpass = LowPassFilter1d(stride: ratio, kernelSize: kernelSize, filter: filter)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        return lowpass(x)
    }
}

class Activation1d: Module {
    let act: SnakeBeta
    let upsample: UpSample1d
    let downsample: DownSample1d

    init(activation: SnakeBeta, upFilter: MLXArray, downFilter: MLXArray) {
        self.act = activation
        self.upsample = UpSample1d(ratio: 2, kernelSize: 12, filter: upFilter)
        self.downsample = DownSample1d(ratio: 2, kernelSize: 12, filter: downFilter)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = upsample(x)
        h = act(h)
        return downsample(h)
    }
}

class AMPBlock1: Module {
    let convs1: [VaeConv1d]
    let convs2: [VaeConv1d]
    let activations: [Activation1d]

    init(channels: Int, kernelSize: Int, dilation: [Int],
                convs1Weights: [MLXArray], convs1Biases: [MLXArray],
                convs2Weights: [MLXArray], convs2Biases: [MLXArray],
                alphas: [MLXArray], betas: [MLXArray],
                upFilters: [MLXArray], downFilters: [MLXArray]) {

        var c1: [VaeConv1d] = []
        var c2: [VaeConv1d] = []
        var acts: [Activation1d] = []

        let numLayers = dilation.count
        for i in 0 ..< numLayers {
            let d = dilation[i]
            let p = (kernelSize * d - d) / 2

            let conv1 = VaeConv1d(weight: convs1Weights[i].transposed(0, 2, 1), bias: convs1Biases[i], stride: 1, padding: p, dilation: d)
            c1.append(conv1)

            let conv2 = VaeConv1d(weight: convs2Weights[i].transposed(0, 2, 1), bias: convs2Biases[i], stride: 1, padding: (kernelSize - 1) / 2, dilation: 1)
            c2.append(conv2)

            let act1 = SnakeBeta(alpha: alphas[2 * i], beta: betas[2 * i])
            let blockAct1 = Activation1d(activation: act1, upFilter: upFilters[2 * i], downFilter: downFilters[2 * i])
            acts.append(blockAct1)

            let act2 = SnakeBeta(alpha: alphas[2 * i + 1], beta: betas[2 * i + 1])
            let blockAct2 = Activation1d(activation: act2, upFilter: upFilters[2 * i + 1], downFilter: downFilters[2 * i + 1])
            acts.append(blockAct2)
        }

        self.convs1 = c1
        self.convs2 = c2
        self.activations = acts
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var x = x
        for i in 0 ..< convs1.count {
            let a1 = activations[2 * i]
            let a2 = activations[2 * i + 1]
            let c1 = convs1[i]
            let c2 = convs2[i]

            var xt = a1(x)
            xt = c1(xt)
            xt = a2(xt)
            xt = c2(xt)
            x = xt + x
        }
        return x
    }
}

class BigVGAN: Module {
    let convPre: VaeConv1d
    let ups: [VaeConvTransposed1d]
    let resblocks: [AMPBlock1]
    let activationPost: Activation1d
    let convPost: VaeConv1d
    let numKernels: Int
    let numUpsamples: Int

    init(numMels: Int, upsampleInitialChannel: Int,
                upsampleRates: [Int] = [5, 5, 2, 2, 2, 2, 2],
                upsampleKernelSizes: [Int] = [9, 9, 4, 4, 4, 4, 4],
                resblockKernelSizes: [Int] = [3, 7, 11],
                resblockDilationSizes: [[Int]] = [[1, 3, 5], [1, 3, 5], [1, 3, 5]],
                weights: [String: MLXArray]) throws {

        func get(_ name: String) throws -> MLXArray {
            guard let a = weights[name] else {
                throw H3BaseWeights.Error.missing(name)
            }
            return a
        }

        self.numKernels = resblockKernelSizes.count
        self.numUpsamples = upsampleRates.count

        let preW = try get("decoder.conv_pre.weight")
        let preB = try get("decoder.conv_pre.bias")
        self.convPre = VaeConv1d(weight: preW.transposed(0, 2, 1), bias: preB, stride: 1, padding: 3)

        var upModules: [VaeConvTransposed1d] = []
        for i in 0 ..< numUpsamples {
            let u = upsampleRates[i]
            let k = upsampleKernelSizes[i]
            let p = (k - u) / 2

            let upW = try get("decoder.ups.\(i).0.weight")
            let upB = try get("decoder.ups.\(i).0.bias")

            let up = VaeConvTransposed1d(weight: upW.transposed(1, 2, 0), bias: upB, stride: u, padding: p)
            upModules.append(up)
        }
        self.ups = upModules

        var blocks: [AMPBlock1] = []
        for i in 0 ..< numUpsamples {
            let ch = upsampleInitialChannel / Int(pow(2.0, Double(i + 1)))
            for j in 0 ..< numKernels {
                let k = resblockKernelSizes[j]
                let d = resblockDilationSizes[j]
                let idx = i * numKernels + j
                let p = "decoder.resblocks.\(idx)."

                var convs1W: [MLXArray] = []
                var convs1B: [MLXArray] = []
                var convs2W: [MLXArray] = []
                var convs2B: [MLXArray] = []
                var alphas: [MLXArray] = []
                var betas: [MLXArray] = []
                var upFilters: [MLXArray] = []
                var downFilters: [MLXArray] = []

                for l in 0 ..< d.count {
                    convs1W.append(try get(p + "convs1.\(l).weight"))
                    convs1B.append(try get(p + "convs1.\(l).bias"))
                    convs2W.append(try get(p + "convs2.\(l).weight"))
                    convs2B.append(try get(p + "convs2.\(l).bias"))
                }
                for l in 0 ..< 2 * d.count {
                    alphas.append(try get(p + "activations.\(l).act.alpha"))
                    betas.append(try get(p + "activations.\(l).act.beta"))
                    upFilters.append(try get(p + "activations.\(l).upsample.filter"))
                    downFilters.append(try get(p + "activations.\(l).downsample.lowpass.filter"))
                }

                let block = AMPBlock1(
                    channels: ch, kernelSize: k, dilation: d,
                    convs1Weights: convs1W, convs1Biases: convs1B,
                    convs2Weights: convs2W, convs2Biases: convs2B,
                    alphas: alphas, betas: betas,
                    upFilters: upFilters, downFilters: downFilters
                )
                blocks.append(block)
            }
        }
        self.resblocks = blocks

        let postAlpha = try get("decoder.activation_post.act.alpha")
        let postBeta = try get("decoder.activation_post.act.beta")
        let postUpF = try get("decoder.activation_post.upsample.filter")
        let postDownF = try get("decoder.activation_post.downsample.lowpass.filter")
        self.activationPost = Activation1d(
            activation: SnakeBeta(alpha: postAlpha, beta: postBeta),
            upFilter: postUpF, downFilter: postDownF
        )

        let postW = try get("decoder.conv_post.weight")
        self.convPost = VaeConv1d(weight: postW.transposed(0, 2, 1), bias: nil, stride: 1, padding: 3)

        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var x = convPre(x)
        for i in 0 ..< numUpsamples {
            x = ups[i](x)
            var xs: MLXArray? = nil
            for j in 0 ..< numKernels {
                let block = resblocks[i * numKernels + j]
                let bx = block(x)
                if let s = xs {
                    xs = s + bx
                } else {
                    xs = bx
                }
            }
            x = xs! / Float(numKernels)
        }
        x = activationPost(x)
        let post = convPost(x)
        return minimum(maximum(post, -1.0), 1.0)
    }
}

final class H3AudioVAE {
    let url: URL
    let latentsMean: MLXArray
    let latentsStd: MLXArray
    let decInProj: VaeConv1d
    let decoder: BigVGAN

    init(url: URL) throws {
        self.url = url
        let w = try H3Loader.loadWeights(from: url)

        func get(_ name: String) throws -> MLXArray {
            guard let a = w[name] else {
                throw H3BaseWeights.Error.missing(name)
            }
            return a
        }

        self.latentsMean = try get("latents_mean")
        self.latentsStd = try get("latents_std")

        let inW = try get("dec_in_proj.weight")
        let inB = try get("dec_in_proj.bias")
        self.decInProj = VaeConv1d(weight: inW.transposed(0, 2, 1), bias: inB, stride: 1, padding: 0)

        self.decoder = try BigVGAN(numMels: 2048, upsampleInitialChannel: 1024, weights: w)
    }

    convenience init(hub: HubApi, configuration: H3Configuration) throws {
        try self.init(
            url: H3Loader.resolve(
                hub: hub,
                configuration: configuration,
                key: "audioVAEWeights"))
    }

    func decode(_ z: MLXArray) -> MLXArray {
        let b = z.dim(0)
        let c = z.dim(1)
        let s = z.dim(2)
        let t = z.dim(3)

        let zPerm = z.transposed(0, 2, 1, 3)
        var flatZ = zPerm.reshaped([b * s, c, t])

        let mean = latentsMean.reshaped([1, c, 1])
        let std = latentsStd.reshaped([1, c, 1])
        flatZ = flatZ * std + mean

        let flatZT = flatZ.transposed(0, 2, 1)

        var x = decInProj(flatZT)
        x = decoder(x)

        let L = x.dim(1)
        var out = x.reshaped([b, s, L])

        let N = Float(s * L)
        let outMean = out.mean(axes: [1, 2], keepDims: true)
        let biasedVar = (out - outMean).square().mean(axes: [1, 2], keepDims: true)
        let unbiasedVar = biasedVar * (N / (N - 1.0))
        var outStd = sqrt(unbiasedVar) * 5.0

        outStd = maximum(outStd, 1.0)
        out = out / outStd
        return out
    }
}

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Kammerich


/// `EncoderFCN3D` — the conv half of the MiniMax H3 Visual VAE.
///
/// The encoder and the decoder are **not** mirror images: the decoder is a ViT
/// (`ViT3DDecoder`, 440 tensors in the model export), this is a 6-level causal-conv
/// ResNet (116 tensors). Porting one teaches you nothing about the other.
///
/// Convolutions run in MLX's channels-last layout; the model's own tensors stay
/// in the reference's `[B, C, T, H, W]` between blocks, and each conv transposes
/// in and out. That keeps the shapes readable against `comfy/ldm/minimax/vae.py`
/// at the cost of some shuffling.

/// Spatial tiling, shared by encode and decode.
///
/// Lifted out of ``H3VisualVAE`` — which had them as instance methods that never
/// touched instance state — so the encoder can reuse them rather than grow a
/// second copy that drifts.
