//
//  H3AudioVAE.swift
//  ModelCraft
//
//  Created by Hongshen on 27/8/26.
//

import Foundation
import MLX
import MLXFast
import MLXNN


/// The Audio VAE, both directions.
///
/// A `Module` whose parts are declared under the checkpoint's own names and
/// filled by ``H3Loader/loadAudioVAE(hub:configuration:)`` from one read of the
/// file — 0.61 GB, read whole. Splitting it into blocks would cost more than it
/// saves.
///
/// The encoder is private and reached through ``encode(_:)`` on the VAE: a caller
/// gets the VAE and never one of its halves, the same rule ``H3VisualVAE``
/// follows and ``H3Encoder`` before it.
final class H3AudioVAE: Module {
    let configuration: H3Configuration
    /// This component's own dimensions, out of the one configuration.
    var config: H3AudioVAEConfiguration { configuration.audioVAE }

    /// The latent normalization, which this checkpoint keeps in
    /// `audio_vae/config.json` rather than among its weights — the same place the
    /// video VAE's lives, and for the same reason: the safetensors file has no
    /// `latents_mean` tensor to read.
    private let latentsMean: [Float]
    private let latentsStd: [Float]

    /// The other direction: the same checkpoint, 0.30 GB of it, reached only for
    /// an audio reference or a video soundtrack.
    @ModuleInfo var encoder: H3AudioVAEEncoder
    /// The kernel-1 convolution up from the latent, stored plainly: it is the one
    /// convolution here BigVGAN does not own and does not weight-normalize.
    @ModuleInfo(key: "dec_in_proj") var decInProj: VaeConv1d
    @ModuleInfo var decoder: H3AudioVAEDecoder

    /// The declaration, with every parameter present but unread. The loader
    /// translates the checkpoint names and fills the complete tree.
    init(configuration: H3Configuration) {
        self.configuration = configuration
        self.latentsMean = configuration.audioVAE.latentsMean
        self.latentsStd = configuration.audioVAE.latentsStd

        let c = configuration.audioVAE
        self._encoder.wrappedValue = H3AudioVAEEncoder(configuration: c)
        self._decInProj.wrappedValue = VaeConv1d(
            weightShape: [c.latentDim, c.latentChannels, 1],
            biasShape: [c.latentDim])
        self._decoder.wrappedValue = H3AudioVAEDecoder(configuration: c)
    }

    /// A waveform through the encoder half, on its way to latent rows.
    ///
    /// This type is the decoder by nature and the encoder by delegation; callers
    /// see one component either way.
    func encode(_ waveform: MLXArray) throws -> MLXArray {
        try encoder(waveform)
    }

    func decode(_ z: MLXArray) throws -> MLXArray {
        let b = z.dim(0)
        let c = z.dim(1)
        let s = z.dim(2)
        let t = z.dim(3)

        let zPerm = z.transposed(0, 2, 1, 3)
        var flatZ = zPerm.reshaped([b * s, c, t])

        let mean = MLXArray(latentsMean).reshaped([1, c, 1])
        let std = MLXArray(latentsStd).reshaped([1, c, 1])
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


/// `x + sin²(αx) / β`.
///
/// The one curve both activations use; the difference between them is only how
/// α and β are stored.
private func snake(_ x: MLXArray, alpha: MLXArray, beta: MLXArray) -> MLXArray {
    let t = sin(alpha * x)
    return (t * t) / (beta + 1e-9) + x
}


// MARK: - Activations

/// The encoder's activation.
///
/// One parameter, not two: the checkpoint stores a single `alpha` per unit and
/// the reference passes it as the divisor as well, so a declaration carrying a
/// separate `beta` would be asking the file for a tensor it does not have.
final class Snake1d: Module {
    /// Stored **raw**, not in log scale — that is ``SnakeBeta``, which is the
    /// decoder's activation.
    @ParameterInfo var alpha: MLXArray

    /// The declaration's placeholder — the shape `update` replaces.
    init(dimensions: Int) {
        self._alpha.wrappedValue = MLXArray.ones([1, dimensions, 1])
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        // The model export stores [1, C, 1]; NLC wants [1, 1, C].
        let a = alpha.reshaped([1, 1, alpha.size])
        return snake(x, alpha: a, beta: a)
    }
}

/// The decoder's activation: the same curve with α and β read through `exp`.
///
/// Unlike ``Snake1d`` these really are two tensors, and the checkpoint has both.
final class SnakeBeta: Module {
    @ParameterInfo var alpha: MLXArray
    @ParameterInfo var beta: MLXArray

    init(dimensions: Int) {
        self._alpha.wrappedValue = MLXArray.zeros([dimensions])
        self._beta.wrappedValue = MLXArray.zeros([dimensions])
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let a = exp(alpha).reshaped([1, 1, alpha.dim(0)])
        let b = exp(beta).reshaped([1, 1, beta.dim(0)])
        return snake(x, alpha: a, beta: b)
    }
}


// MARK: - Convolutions

/// A 1-D convolution stored the plain way, as PyTorch keeps it, `[out, in, k]`.
///
/// Only `dec_in_proj` is one — it is the single convolution in this component
/// that BigVGAN does not own and does not weight-normalize. MLX wants
/// `[out, k, in]`, so the transpose happens at the call: it is a view, free to
/// take, and taking it here is what lets the declaration hold the checkpoint's
/// own layout.
final class VaeConv1d: Module {
    @ParameterInfo var weight: MLXArray
    @ParameterInfo var bias: MLXArray?
    let stride: Int
    let padding: Int

    /// The declaration's placeholder — the shapes `update` replaces.
    init(weightShape: [Int], biasShape: [Int], stride: Int = 1, padding: Int = 0) {
        self.stride = stride
        self.padding = padding
        self._weight.wrappedValue = MLXArray.zeros(weightShape)
        self._bias.wrappedValue = MLXArray.zeros(biasShape)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var out = conv1d(x, weight.transposed(0, 2, 1),
                         stride: stride, padding: padding, dilation: 1)
        if let bias { out = out + bias.reshaped([1, 1, bias.dim(0)]) }
        return out
    }
}

/// A 1-D convolution the checkpoint stores **weight-normalized**.
///
/// This is how BigVGAN and the audio encoder parameterize every convolution they
/// own, so what the file holds is a magnitude `weight_g` and a direction
/// `weight_v` rather than a weight. Both are declared exactly as the file spells
/// them and combined where the convolution runs; the alternative — undoing the
/// normalization at load — would put a tensor the checkpoint does not have where
/// its own tensors go, and the declaration would stop being a mirror of the file.
///
/// The pair is small (the widest is 512×512×3) and the decoder runs once a
/// render, so recomputing the product costs less than carrying it.
final class VaeNormConv1d: Module {
    @ParameterInfo(key: "weight_g") var weightG: MLXArray
    @ParameterInfo(key: "weight_v") var weightV: MLXArray
    @ParameterInfo var bias: MLXArray?
    let stride: Int
    let padding: Int
    let dilation: Int

    /// The declaration's placeholder — the shapes `update` replaces.
    init(outChannels: Int, inChannels: Int, kernelSize: Int, hasBias: Bool = true,
         stride: Int = 1, padding: Int = 0, dilation: Int = 1) {
        self.stride = stride
        self.padding = padding
        self.dilation = dilation
        self._weightG.wrappedValue = MLXArray.ones([outChannels, 1, 1])
        self._weightV.wrappedValue = MLXArray.zeros([outChannels, inChannels, kernelSize])
        self._bias.wrappedValue = hasBias ? MLXArray.zeros([outChannels]) : nil
    }

    /// `weight_g * weight_v / ‖weight_v‖₂`, the norm taken over every axis but
    /// the first — PyTorch's `weight_norm(dim: 0)`.
    private var weight: MLXArray {
        let norm = sqrt(sum(weightV * weightV,
                           axes: Array(1 ..< weightV.ndim), keepDims: true))
        return weightG * weightV / norm
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var out = conv1d(x, weight.transposed(0, 2, 1),
                         stride: stride, padding: padding, dilation: dilation)
        if let bias { out = out + bias.reshaped([1, 1, bias.dim(0)]) }
        return out
    }
}

/// The transposed counterpart of ``VaeNormConv1d``, for the decoder's upsample
/// stages.
///
/// PyTorch stores a transposed convolution `[in, out, k]`, so the transpose to
/// MLX's `[out, k, in]` is `(1, 2, 0)` rather than `(0, 2, 1)`.
final class VaeNormConvTransposed1d: Module {
    @ParameterInfo(key: "weight_g") var weightG: MLXArray
    @ParameterInfo(key: "weight_v") var weightV: MLXArray
    @ParameterInfo var bias: MLXArray?
    let stride: Int
    let padding: Int

    /// The declaration's placeholder — the shapes `update` replaces.
    init(inChannels: Int, outChannels: Int, kernelSize: Int,
         stride: Int, padding: Int) {
        self.stride = stride
        self.padding = padding
        self._weightG.wrappedValue = MLXArray.ones([outChannels, 1, 1])
        self._weightV.wrappedValue = MLXArray.zeros([inChannels, outChannels, kernelSize])
        self._bias.wrappedValue = MLXArray.zeros([outChannels])
    }

    /// `weight_g * weight_v / ‖weight_v‖₂`, over every axis but the first.
    private var weight: MLXArray {
        let norm = sqrt(sum(weightV * weightV,
                           axes: Array(1 ..< weightV.ndim), keepDims: true))
        return weightG * weightV / norm
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var out = convTransposed1d(x, weight.transposed(1, 2, 0),
                                   stride: stride, padding: padding)
        if let bias { out = out + bias.reshaped([1, 1, bias.dim(0)]) }
        return out
    }
}

/// A linear map with a weight and no bias of its own.
///
/// `pre_block.attn.qkv` is one: its bias is three separate tensors — `q_bias`, a
/// registered `zero_k_bias` and `v_bias` — that the attention concatenates, so a
/// declaration carrying a single `bias` would be looking for a tensor the
/// checkpoint does not have.
final class AudioLinear: Module {
    @ParameterInfo var weight: MLXArray

    /// The declaration's placeholder — the shape `update` replaces.
    init(outputDimensions: Int, inputDimensions: Int) {
        self._weight.wrappedValue = MLXArray.zeros([outputDimensions, inputDimensions])
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        matmul(x, weight.T)
    }
}


// MARK: - Resampling

/// The zero-stuffed upsample BigVGAN wraps every activation in.
///
/// `Scaling` is not a constant to write down: the kernel is the checkpoint's own
/// filter, so its length is read off that tensor rather than restated here.
final class UpSample1d: Module {
    @ParameterInfo var filter: MLXArray
    /// Part of the activation's design, not a dimension of the checkpoint.
    let ratio: Int

    /// Read off the filter: the export stores it `[1, 1, kernelSize]`, so its
    /// last axis *is* the kernel.
    private var kernelSize: Int { filter.dim(filter.ndim - 1) }
    private var pad: Int { kernelSize / ratio - 1 }
    private var padLeft: Int { pad * ratio + (kernelSize - ratio) / 2 }
    private var padRight: Int { pad * ratio + (kernelSize - ratio + 1) / 2 }

    /// The declaration's placeholder — the shape `update` replaces.
    init(ratio: Int = 2, filterLength: Int = 12) {
        self.ratio = ratio
        self._filter.wrappedValue = MLXArray.zeros([1, 1, filterLength])
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

        var out = convTransposed1d(paddedX, weight.asType(x.dtype),
                                   stride: ratio, padding: 0, groups: C)
        out = out * Float(ratio)

        let s = padLeft
        let e = out.dim(1) - padRight
        let indices: [any MLXArrayIndex] = [0 ..< out.dim(0), s ..< e, 0 ..< out.dim(2)]
        return out[indices]
    }
}

/// The anti-aliasing filter the downsample runs through.
final class LowPassFilter1d: Module {
    @ParameterInfo var filter: MLXArray
    let stride: Int

    private var kernelSize: Int { filter.dim(filter.ndim - 1) }
    private var padLeft: Int { kernelSize / 2 - (kernelSize % 2 == 0 ? 1 : 0) }
    private var padRight: Int { kernelSize / 2 }

    /// The declaration's placeholder — the shape `update` replaces.
    init(stride: Int = 1, filterLength: Int = 12) {
        self.stride = stride
        self._filter.wrappedValue = MLXArray.zeros([1, 1, filterLength])
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

final class DownSample1d: Module {
    @ModuleInfo var lowpass: LowPassFilter1d

    init(ratio: Int = 2, filterLength: Int = 12) {
        self._lowpass.wrappedValue = LowPassFilter1d(
            stride: ratio, filterLength: filterLength)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        lowpass(x)
    }
}

/// `upsample -> activate -> downsample`.
///
/// The activation runs at twice the sample rate and is filtered back down, which
/// is what stops BigVGAN's aliasing from turning into audible artefacts.
final class Activation1d: Module {
    @ModuleInfo var act: SnakeBeta
    @ModuleInfo var upsample: UpSample1d
    @ModuleInfo var downsample: DownSample1d

    /// The declaration's placeholder — `update` replaces the filter shapes, and
    /// every derived width is read back off them.
    init(dimensions: Int) {
        self._act.wrappedValue = SnakeBeta(dimensions: dimensions)
        self._upsample.wrappedValue = UpSample1d()
        self._downsample.wrappedValue = DownSample1d()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = upsample(x)
        h = act(h)
        return downsample(h)
    }
}


// MARK: - Encoder

/// `Snake1d -> Conv1d(k=7, dilation=d) -> Snake1d -> Conv1d(k=1)`, plus residual.
///
/// The dilation is the whole point of the unit — the three units in a block run
/// at 1, 3 and 9, which is what gives the encoder its receptive field. Running
/// them all at dilation 1 leaves every shape correct.
///
/// The checkpoint spells the four components `block.0` … `block.3`; the loader
/// maps those indices onto these named properties.
final class AudioResidualUnit: Module {
    @ModuleInfo var act1: Snake1d
    @ModuleInfo var conv1: VaeNormConv1d
    @ModuleInfo var act2: Snake1d
    @ModuleInfo var conv2: VaeNormConv1d

    init(dimensions: Int, dilation: Int) {
        self._act1.wrappedValue = Snake1d(dimensions: dimensions)
        self._conv1.wrappedValue = VaeNormConv1d(
            outChannels: dimensions, inChannels: dimensions,
            kernelSize: 7, padding: (7 - 1) * dilation / 2, dilation: dilation)
        self._act2.wrappedValue = Snake1d(dimensions: dimensions)
        self._conv2.wrappedValue = VaeNormConv1d(
            outChannels: dimensions, inChannels: dimensions,
            kernelSize: 1, padding: 0)
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
final class AudioEncoderBlock: Module {
    @ModuleInfo var units: [AudioResidualUnit]
    @ModuleInfo var act: Snake1d
    @ModuleInfo var down: VaeNormConv1d

    init(inChannels: Int, outChannels: Int, stride: Int) {
        self._units.wrappedValue = [1, 3, 9].map {
            AudioResidualUnit(dimensions: inChannels, dilation: $0)
        }
        self._act.wrappedValue = Snake1d(dimensions: inChannels)
        // The kernel is 2*stride and the padding is ceil(stride/2) — NOT
        // (kernel-stride)/2, which agrees for even strides and is wrong by one
        // for stride 5. The export confirms the kernel: 4, 8, 8, 10, 10.
        self._down.wrappedValue = VaeNormConv1d(
            outChannels: outChannels, inChannels: inChannels,
            kernelSize: 2 * stride, stride: stride, padding: (stride + 1) / 2)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = x
        for u in units { h = u(h) }
        return down(act(h))
    }
}

/// Causal attention that also pools the reference's 2048 channels down to the
/// 32-wide latent.
///
/// The pooling is `adaptive_avg_pool1d(mean_over_heads(attn), 32)`. With 8 heads
/// the head dim is 256, and 256/32 = 8, so it is a mean over consecutive groups
/// of 8. Dropping the pool and picking a head count that happens to make the
/// head dim 32 gives the right shape and the wrong values.
final class AudioCausalAttention: Module {
    @ModuleInfo var qkv: AudioLinear
    /// `q_bias | zero_k_bias | v_bias`. The k half is a registered buffer of
    /// zeros in the reference, present so the concatenation has the right width,
    /// and the checkpoint carries it like any other tensor.
    @ParameterInfo(key: "q_bias") var qBias: MLXArray
    @ParameterInfo(key: "zero_k_bias") var zeroKBias: MLXArray
    @ParameterInfo(key: "v_bias") var vBias: MLXArray
    @ModuleInfo var proj: H3Projection
    let heads: Int
    let headDim: Int
    let outDim: Int

    init(inDim: Int, outDim: Int, heads: Int) {
        self.heads = heads
        self.headDim = inDim / heads
        self.outDim = outDim
        self._qkv.wrappedValue = AudioLinear(
            outputDimensions: 3 * inDim, inputDimensions: inDim)
        self._qBias.wrappedValue = MLXArray.zeros([inDim])
        self._zeroKBias.wrappedValue = MLXArray.zeros([inDim])
        self._vBias.wrappedValue = MLXArray.zeros([inDim])
        self._proj.wrappedValue = H3Projection(
            inputDimensions: outDim, outputDimensions: outDim)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let b = x.dim(0), n = x.dim(1)
        let qkvBias = concatenated([qBias, zeroKBias, vBias], axis: 0)
        let f = qkv(x) + qkvBias
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
        return proj(down)
    }
}

/// `w2(gelu_tanh(w0(x)) * w1(x))` — note which branch is activated.
final class AudioGeGluMlp: Module {
    @ModuleInfo var norm: VaeLayerNorm
    @ModuleInfo var w0: H3Projection
    @ModuleInfo var w1: H3Projection
    @ModuleInfo var w2: H3Projection

    init(dimensions: Int) {
        let inner = 2 * dimensions
        self._norm.wrappedValue = VaeLayerNorm(dimensions: dimensions)
        self._w0.wrappedValue = H3Projection(
            inputDimensions: dimensions, outputDimensions: inner)
        self._w1.wrappedValue = H3Projection(
            inputDimensions: dimensions, outputDimensions: inner)
        self._w2.wrappedValue = H3Projection(
            inputDimensions: inner, outputDimensions: dimensions)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let h = norm(x)
        // GELU is the tanh approximation in the reference, not the exact erf form.
        let a = geluApproximate(w0(h))
        let b = w1(h)
        return w2(a * b)
    }
}

/// The encoder's posterior head: a projection and an attention in parallel,
/// summed, then a GeGLU residual.
final class AudioAttnProjection: Module {
    @ModuleInfo var norm1: VaeLayerNorm
    @ModuleInfo var norm2: VaeLayerNorm
    @ModuleInfo var norm3: VaeLayerNorm
    @ModuleInfo var attn: AudioCausalAttention
    @ModuleInfo var proj: H3Projection
    @ModuleInfo var mlp: AudioGeGluMlp

    init(inDim: Int, outDim: Int, heads: Int) {
        self._norm1.wrappedValue = VaeLayerNorm(dimensions: inDim)
        self._norm2.wrappedValue = VaeLayerNorm(dimensions: outDim)
        self._norm3.wrappedValue = VaeLayerNorm(dimensions: inDim)
        // 8 heads, not 64 — the head dim is what the adaptive pool consumes.
        self._attn.wrappedValue = AudioCausalAttention(
            inDim: inDim, outDim: outDim, heads: heads)
        self._proj.wrappedValue = H3Projection(
            inputDimensions: inDim, outputDimensions: outDim)
        self._mlp.wrappedValue = AudioGeGluMlp(dimensions: outDim)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let h = proj(norm3(x)) + attn(norm1(x))
        return h + mlp(norm2(h))
    }
}


// MARK: - Decoder

/// One BigVGAN anti-aliased multi-periodicity block: `dilation.count` residual
/// pairs, each with its own activation.
final class AMPBlock1: Module {
    @ModuleInfo var convs1: [VaeNormConv1d]
    @ModuleInfo var convs2: [VaeNormConv1d]
    @ModuleInfo var activations: [Activation1d]

    init(dimensions: Int, kernelSize: Int, dilation: [Int]) {
        self._convs1.wrappedValue = dilation.map { d in
            VaeNormConv1d(outChannels: dimensions, inChannels: dimensions,
                          kernelSize: kernelSize, padding: (kernelSize * d - d) / 2,
                          dilation: d)
        }
        self._convs2.wrappedValue = dilation.map { _ in
            VaeNormConv1d(outChannels: dimensions, inChannels: dimensions,
                          kernelSize: kernelSize, padding: (kernelSize - 1) / 2)
        }
        // Two activations per residual pair, in the order the forward reads them.
        self._activations.wrappedValue = (0 ..< 2 * dilation.count).map { _ in
            Activation1d(dimensions: dimensions)
        }
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var x = x
        for i in 0 ..< convs1.count {
            let a1 = activations[2 * i]
            let a2 = activations[2 * i + 1]
            x = convs2[i](a2(convs1[i](a1(x)))) + x
        }
        return x
    }
}

/// The decoder proper: a projection up from the latent, then alternating
/// upsample stages and residual-block stacks, then out to a waveform.
final class H3AudioVAEDecoder: Module {
    /// No `key:` overrides here either — the loader folds the file's `conv_pre`,
    /// `activation_post` and `conv_post` onto these names.
    @ModuleInfo var convPre: VaeNormConv1d
    @ModuleInfo var ups: [VaeNormConvTransposed1d]
    @ModuleInfo var resblocks: [AMPBlock1]
    @ModuleInfo var activationPost: Activation1d
    @ModuleInfo var convPost: VaeNormConv1d
    let numKernels: Int
    let numUpsamples: Int

    init(configuration: H3AudioVAEConfiguration) {
        let c = configuration
        self.numKernels = c.numKernels
        self.numUpsamples = c.decoderRates.count

        self._convPre.wrappedValue = VaeNormConv1d(
            outChannels: c.decoderDim, inChannels: c.latentDim,
            kernelSize: 7, padding: 3)

        self._ups.wrappedValue = (0 ..< c.decoderRates.count).map { i in
            let rate = c.decoderRates[i]
            let kernel = c.decoderKernelSizes[i]
            return VaeNormConvTransposed1d(
                inChannels: i == 0 ? c.decoderDim : c.decoderChannels[i - 1],
                outChannels: c.decoderChannels[i],
                kernelSize: kernel, stride: rate, padding: (kernel - rate) / 2)
        }

        self._resblocks.wrappedValue = (0 ..< c.decoderRates.count).flatMap { i in
            (0 ..< c.numKernels).map { j in
                AMPBlock1(dimensions: c.decoderChannels[i],
                          kernelSize: c.resblockKernelSizes[j],
                          dilation: c.resblockDilationSizes[j])
            }
        }

        guard let finalChannels = c.decoderChannels.last else {
            preconditionFailure("the audio VAE's decoder has no upsample stages")
        }
        self._activationPost.wrappedValue = Activation1d(dimensions: finalChannels)
        // The output convolution carries no bias — the checkpoint has no
        // `conv_post.bias` to give it.
        self._convPost.wrappedValue = VaeNormConv1d(
            outChannels: 1, inChannels: finalChannels,
            kernelSize: 7, hasBias: false, padding: 3)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var x = convPre(x)
        for i in 0 ..< numUpsamples {
            x = ups[i](x)
            var xs: MLXArray? = nil
            for j in 0 ..< numKernels {
                let bx = resblocks[i * numKernels + j](x)
                xs = xs.map { $0 + bx } ?? bx
            }
            x = xs! / Float(numKernels)
        }
        x = activationPost(x)
        return minimum(maximum(convPost(x), -1.0), 1.0)
    }
}


// MARK: - Components

/// The audio encoder: a stereo waveform to normalized latents.
///
/// Its parameter shapes and forward pass are declared here; checkpoint name
/// translation and loading belong to ``H3Loader/loadAudioVAE(hub:configuration:)``.
final class H3AudioVAEEncoder: Module {
    /// This component's own dimensions, out of the one configuration.
    let config: H3AudioVAEConfiguration

    /// The latent normalization the encoder inverts on its way out. Swift arrays,
    /// not `MLXArray`s: a `Module` walks its `MLXArray` ivars as the weights a
    /// load fills.
    private let latentsMean: [Float]
    private let latentsStd: [Float]

    /// These carry no `key:` overrides because the loader re-keys the checkpoint's
    /// `conv_in`, `pre_block` and the rest onto these property names.
    @ModuleInfo var convIn: VaeNormConv1d
    @ModuleInfo var blocks: [AudioEncoderBlock]
    @ModuleInfo var actOut: Snake1d
    @ModuleInfo var convOut: VaeNormConv1d
    @ModuleInfo var preBlock: AudioAttnProjection
    /// The kernel-1 convolution that mixes the pooled channels, used as a matmul
    /// because its stride equals its kernel.
    @ModuleInfo var meanProj: H3Projection

    /// The declaration, with every parameter present but unread.
    init(configuration c: H3AudioVAEConfiguration) {
        self.config = c
        self.latentsMean = c.latentsMean
        self.latentsStd = c.latentsStd

        let channels = c.encoderChannels

        // The encoder is mono; `encode` runs the two stereo channels through it
        // as a batch, which is why the input width is one and not two.
        self._convIn.wrappedValue = VaeNormConv1d(
            outChannels: channels[0], inChannels: 1, kernelSize: 7, padding: 3)
        self._blocks.wrappedValue = c.encoderRates.enumerated().map { i, rate in
            AudioEncoderBlock(inChannels: channels[i], outChannels: channels[i + 1],
                              stride: rate)
        }
        self._actOut.wrappedValue = Snake1d(dimensions: channels[channels.count - 1])
        self._convOut.wrappedValue = VaeNormConv1d(
            outChannels: c.latentDim,
            inChannels: channels[channels.count - 1],
            kernelSize: 3, padding: 1)
        self._preBlock.wrappedValue = AudioAttnProjection(
            inDim: c.latentDim,
            outDim: c.latentChannels,
            heads: c.numAttentionHeads)
        self._meanProj.wrappedValue = H3Projection(
            weightShape: [c.latentChannels, c.latentChannels, 1],
            biasShape: [c.latentChannels])
    }

    /// Stereo waveform `[B, 2, L]` in [-1, 1] -> normalized latents `[B, 32, 2, T]`.
    ///
    /// The encoder is the whole of this module's job, so it is the module's call
    /// operator rather than a method on it.
    func callAsFunction(_ waveform: MLXArray) throws -> MLXArray {
        let b = waveform.dim(0), s = waveform.dim(1), l = waveform.dim(2)
        let padded = (l + config.hopLength - 1) / config.hopLength * config.hopLength
        var w = waveform
        if padded > l {
            w = concatenated([w, MLXArray.zeros([b, s, padded - l], dtype: w.dtype)], axis: -1)
        }
        // stereo channels run through the mono encoder independently
        var x = w.reshaped([b * s, 1, padded]).transposed(0, 2, 1)   // [B*S, L, 1]

        x = convIn(x)
        for block in blocks {
            x = block(x)
        }
        x = actOut(x)
        x = convOut(x)                                               // [B*S, T, 2048]

        x = preBlock(x)                                              // [B*S, T, 32]

        let channels = config.latentChannels
        let z = matmul(x, meanProj.weight.reshaped([channels, channels]).T) + meanProj.bias
        let zn = (z - MLXArray(latentsMean).reshaped([1, 1, channels]))
               / MLXArray(latentsStd).reshaped([1, 1, channels])

        let t = zn.dim(1)
        return zn.transposed(0, 2, 1)                                // [B*S, 32, T]
                 .reshaped([b, s, channels, t])
                 .transposed(0, 2, 1, 3)                             // [B, 32, 2, T]
    }
}
