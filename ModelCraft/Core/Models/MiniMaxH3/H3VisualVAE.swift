//
//  H3VisualVAE.swift
//  ModelCraft
//
//  Created by Hongshen on 27/8/26.
//


import Foundation
import Hub
import MLX
import MLXFast
import MLXNN

enum VaeTiling {
    static let tileSize = 256
    static let tileOverlapMin = 64
    /// `prod(space_down)` — pixels per latent cell.
    static let vaeRatio = 16

    /// Tile starts, lengths and overlaps for one axis.
    ///
    /// Overlaps are grown in whole `vaeRatio` units so that every latent-space
    /// overlap is an integer; a fractional one would make the blend seams land
    /// between latent cells.
    static func splitTiles(inputLen: Int, tileSize: Int = tileSize,
                                  tileOverlapMin: Int = tileOverlapMin,
                                  vaeRatio: Int = vaeRatio)
        -> (starts: [Int], lengths: [Int], overlaps: [Int]) {
        if tileSize >= inputLen { return ([0], [inputLen], []) }
        var n = Int(ceil(Double(inputLen) / Double(tileSize)))
        var overlaps: [Int] = []
        while true {
            overlaps = Array(repeating: tileOverlapMin, count: n - 1)
            if tileSize * n - overlaps.reduce(0, +) - inputLen < 0 { n += 1 } else { break }
        }
        let remaining = tileSize * n - overlaps.reduce(0, +) - inputLen
        for i in 0 ..< (remaining / vaeRatio) { overlaps[i % (n - 1)] += vaeRatio }
        var starts = [0]
        for i in 0 ..< (n - 1) { starts.append(starts.last! + tileSize - overlaps[i]) }
        return (starts, Array(repeating: tileSize, count: n), overlaps)
    }

    static func sliceDim(_ a: MLXArray, dim: Int, start: Int, end: Int) -> MLXArray {
        let axis = dim < 0 ? a.ndim + dim : dim
        let size = a.dim(axis)
        let s = max(0, min(size, start)), e = max(0, min(size, end))
        var idx: [any MLXArrayIndex] = []
        for i in 0 ..< a.ndim { idx.append(i == axis ? s ..< e : 0 ..< a.dim(i)) }
        return a[idx]
    }

    /// Linear cross-fade of `a`'s trailing `blendExtent` into `b`'s leading one.
    static func blend(_ a: MLXArray, _ b: MLXArray,
                             blendExtent: Int, dim: Int) -> MLXArray {
        let ndim = a.ndim
        // Callers pass -1 and -2. MLXArray.dim() and sliceDim() both accept
        // negative axes; a Swift Array subscript does not, and indexing
        // weightShape[-1] traps. Normalise once, here.
        let axis = dim < 0 ? ndim + dim : dim
        precondition(axis >= 0 && axis < ndim, "blend axis \(dim) outside 0..<\(ndim)")
        let extent = min(a.dim(axis), b.dim(axis), blendExtent)
        if extent <= 0 { return b }

        let positions = MLXArray(0 ..< extent).asType(b.dtype)
        var shape = Array(repeating: 1, count: ndim)
        shape[axis] = extent
        let wA = (1.0 - positions / Float(extent)).reshaped(shape)
        let wB = (positions / Float(extent)).reshaped(shape)

        let blended = sliceDim(a, dim: axis, start: a.dim(axis) - extent, end: a.dim(axis)) * wA
                    + sliceDim(b, dim: axis, start: 0, end: extent) * wB
        if extent < b.dim(axis) {
            return concatenated([blended, sliceDim(b, dim: axis, start: extent, end: b.dim(axis))],
                                axis: axis)
        }
        return blended
    }
}

/// GroupNorm with statistics taken **per frame**: time is folded into the batch
/// so a frame never borrows another frame's mean.
///
/// Written out rather than reached for from MLXNN, because MLXNN's `GroupNorm`
/// normalizes the **last** axis and the reference normalizes the second. Handing
/// it `[B*T, C, 1, H, W]` normalizes over width and is silent about it.
struct TemporalIsolatedGroupNorm {
    let weight: MLXArray
    let bias: MLXArray
    let groups: Int
    /// 1e-6 here, not the 1e-5 that most frameworks default to.
    let eps: Float

    init(weight: MLXArray, bias: MLXArray, groups: Int = 32, eps: Float = 1e-6) {
        self.weight = weight
        self.bias = bias
        self.groups = groups
        self.eps = eps
    }

    /// `x` is `[B, C, T, H, W]`.
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let b = x.dim(0), c = x.dim(1), t = x.dim(2), h = x.dim(3), w = x.dim(4)
        let f = x.asType(.float32)
        // group over channels only; each (frame, group) gets its own statistics
        let g = f.transposed(0, 2, 1, 3, 4).reshaped([b * t, groups, (c / groups) * h * w])
        let mu = mean(g, axis: -1, keepDims: true)
        let d = g - mu
        let v = mean(d * d, axis: -1, keepDims: true)
        let n = (d * rsqrt(v + eps)).reshaped([b, t, c, h, w]).transposed(0, 2, 1, 3, 4)
        let shape = [1, c, 1, 1, 1]
        return (n * weight.asType(.float32).reshaped(shape)
                  + bias.asType(.float32).reshaped(shape)).asType(x.dtype)
    }
}

/// Reflect padding on the spatial axes, causal zero padding on time.
///
/// Causal means the whole temporal pad goes on the **front** and is twice the
/// nominal width — the convolution never sees a future frame.
struct CausalConv3d {
    /// `[O, kT, kH, kW, I]` — MLX's conv3d layout, transposed once at load.
    let weight: MLXArray
    let bias: MLXArray?
    let stride: [Int]
    let padding: (t: Int, h: Int, w: Int)

    init(weight: MLXArray, bias: MLXArray?, stride: [Int] = [1, 1, 1],
         padding: (t: Int, h: Int, w: Int) = (0, 0, 0)) {
        self.weight = weight
        self.bias = bias
        self.stride = stride
        self.padding = padding
    }

    /// Reflect pad, excluding the edge row itself — `F.pad(..., mode="reflect")`.
    private static func reflect(_ x: MLXArray, axis: Int, width: Int) -> MLXArray {
        guard width > 0 else { return x }
        let n = x.dim(axis)
        precondition(width < n, "reflect pad \(width) needs at least \(width + 1) rows on axis \(axis)")
        let lead = (1 ... width).reversed().map { x.take(MLXArray(Int32($0)), axis: axis)
                                                   .expandedDimensions(axis: axis) }
        let tail = (1 ... width).map { x.take(MLXArray(Int32(n - 1 - $0)), axis: axis)
                                        .expandedDimensions(axis: axis) }
        return concatenated(lead + [x] + tail, axis: axis)
    }

    /// `x` is `[B, C, T, H, W]`.
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var p = x
        if padding.h > 0 || padding.w > 0 {
            p = Self.reflect(p, axis: 3, width: padding.h)
            p = Self.reflect(p, axis: 4, width: padding.w)
        }
        if padding.t > 0 {
            // Front-only, double width, zeros. This gives the causal temporal
            // convolution the same left context as the H3 VAE.
            let z = MLXArray.zeros([p.dim(0), p.dim(1), padding.t * 2, p.dim(3), p.dim(4)],
                                   dtype: p.dtype)
            p = concatenated([z, p], axis: 2)
        }
        var out = conv3d(p.transposed(0, 2, 3, 4, 1), weight,
                         stride: .init((stride[0], stride[1], stride[2])),
                         padding: .init((0, 0, 0)))
        if let bias { out = out + bias.reshaped([1, 1, 1, 1, bias.size]) }
        return out.transposed(0, 4, 1, 2, 3)
    }
}

struct VideoResnetBlock3D {
    let norm1: TemporalIsolatedGroupNorm
    let conv1: CausalConv3d
    let norm2: TemporalIsolatedGroupNorm
    let conv2: CausalConv3d
    let ninShortcut: CausalConv3d?

    init(inChannels: Int, outChannels: Int, prefix: String,
         weights: [String: MLXArray]) throws {
        func get(_ n: String) throws -> MLXArray {
            guard let a = weights[n] else { throw H3BaseWeights.Error.missing(n) }
            return a
        }
        self.norm1 = TemporalIsolatedGroupNorm(weight: try get(prefix + "norm1.weight"),
                                               bias: try get(prefix + "norm1.bias"))
        self.norm2 = TemporalIsolatedGroupNorm(weight: try get(prefix + "norm2.weight"),
                                               bias: try get(prefix + "norm2.bias"))
        self.conv1 = CausalConv3d(weight: try get(prefix + "conv1.weight").transposed(0, 2, 3, 4, 1),
                                  bias: try get(prefix + "conv1.bias"), padding: (1, 1, 1))
        self.conv2 = CausalConv3d(weight: try get(prefix + "conv2.weight").transposed(0, 2, 3, 4, 1),
                                  bias: try get(prefix + "conv2.bias"), padding: (1, 1, 1))
        // kernel 1, so no padding at all — the 1x1x1 shortcut is a channel map.
        self.ninShortcut = inChannels == outChannels ? nil
            : CausalConv3d(weight: try get(prefix + "nin_shortcut.weight").transposed(0, 2, 3, 4, 1),
                           bias: try get(prefix + "nin_shortcut.bias"))
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = conv1(silu(norm1(x)))
        h = conv2(silu(norm2(h)))
        return h + (ninShortcut?(x) ?? x)
    }
}

struct VideoDownsample3D {
    let conv: CausalConv3d
    let spaceStride: Int

    init(timeStride: Int, spaceStride: Int, prefix: String,
         weights: [String: MLXArray]) throws {
        func get(_ n: String) throws -> MLXArray {
            guard let a = weights[n] else { throw H3BaseWeights.Error.missing(n) }
            return a
        }
        self.spaceStride = spaceStride
        self.conv = CausalConv3d(weight: try get(prefix + "conv.weight").transposed(0, 2, 3, 4, 1),
                                 bias: try get(prefix + "conv.bias"),
                                 stride: [timeStride, spaceStride, spaceStride],
                                 padding: (1, 0, 0))
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        guard spaceStride == 2 else { return conv(x) }
        // One extra row and column on the trailing edge, reflected — not zeros.
        var p = x
        let h = p.dim(3), w = p.dim(4)
        p = concatenated([p, p[0..., 0..., 0..., (h - 2) ..< (h - 1), 0...]], axis: 3)
        p = concatenated([p, p[0..., 0..., 0..., 0..., (w - 2) ..< (w - 1)]], axis: 4)
        return conv(p)
    }
}

struct VideoEncoderLevel {
    let blocks: [VideoResnetBlock3D]
    let downsample: VideoDownsample3D?

    init(inChannels: Int, midChannels: Int, timeStride: Int, spaceStride: Int,
         numResBlocks: Int, prefix: String, weights: [String: MLXArray]) throws {
        self.blocks = try (0 ..< numResBlocks).map { i in
            try VideoResnetBlock3D(inChannels: i == 0 ? inChannels : midChannels,
                                   outChannels: midChannels,
                                   prefix: prefix + "block.\(i).", weights: weights)
        }
        self.downsample = spaceStride * timeStride > 1
            ? try VideoDownsample3D(timeStride: timeStride, spaceStride: spaceStride,
                                    prefix: prefix + "downsample.", weights: weights)
            : nil
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = x
        for b in blocks { h = b(h) }
        return downsample?(h) ?? h
    }
}

final class H3VisualVAEEncoder {
    /// ImageNet statistics. Pixels arrive in [-1, 1], are mapped to [0, 1], then
    /// standardised by these — the encoder never sees the raw range.
    static let pixelMean: [Float] = [0.485, 0.456, 0.406]
    static let pixelStd: [Float] = [0.229, 0.224, 0.225]

    static let chMult = [1, 2, 2, 4, 4, 8]
    static let spaceDown = [2, 2, 2, 2, 1, 1]
    static let timeDown = [1, 2, 2, 1, 1, 1]
    static let baseCh = 128
    static let numResBlocks = 2
    static let zChannels = 24
    /// 17 frames per temporal clip, and 3 latent tokens dropped per clip.
    static let clipLength = 17
    /// Tokens trimmed from the tail after the clips are concatenated.
    static let tokenDrop = 3
    /// Above this on either spatial axis the reference tiles.
    static let tileSize = 256

    let convIn: CausalConv3d
    let levels: [VideoEncoderLevel]
    let normOut: TemporalIsolatedGroupNorm
    let convOut: CausalConv3d
    let quantConv: MLXArray
    let quantConvBias: MLXArray
    let latentsMean: MLXArray
    let latentsStd: MLXArray

    init(weights: [String: MLXArray]) throws {
        func get(_ n: String) throws -> MLXArray {
            guard let a = weights[n] else { throw H3BaseWeights.Error.missing(n) }
            return a
        }
        self.latentsMean = try get("latents_mean")
        self.latentsStd = try get("latents_std")

        self.convIn = CausalConv3d(weight: try get("encoder.conv_in.weight").transposed(0, 2, 3, 4, 1),
                                   bias: try get("encoder.conv_in.bias"), padding: (1, 1, 1))

        let mid = Self.chMult.map { Self.baseCh * $0 }
        let inputs = [mid[0]] + mid.dropLast()
        self.levels = try (0 ..< Self.chMult.count).map { i in
            try VideoEncoderLevel(inChannels: inputs[i], midChannels: mid[i],
                                  timeStride: Self.timeDown[i], spaceStride: Self.spaceDown[i],
                                  numResBlocks: Self.numResBlocks,
                                  prefix: "encoder.down.\(i).", weights: weights)
        }

        self.normOut = TemporalIsolatedGroupNorm(weight: try get("encoder.norm_out.weight"),
                                                 bias: try get("encoder.norm_out.bias"))
        self.convOut = CausalConv3d(weight: try get("encoder.conv_out.weight").transposed(0, 2, 3, 4, 1),
                                    bias: try get("encoder.conv_out.bias"), padding: (1, 1, 1))
        // Conv3d with kernel 1: [2*embed, 2*z, 1, 1, 1] is a channel matmul.
        let q = try get("quant_conv.weight")
        self.quantConv = q.reshaped([q.dim(0), q.dim(1)])
        self.quantConvBias = try get("quant_conv.bias")
    }

    convenience init(hub: HubApi, configuration: H3Configuration) throws {
        try self.init(
            weights: try H3Loader.loadWeights(
                hub: hub,
                configuration: configuration,
                key: .videoVAEWeights))
    }

    /// The conv stack, returning `[B, 48, T_lat, H/16, W/16]` moments.
    func moments(_ x: MLXArray) -> MLXArray {
        var h = convIn(x)
        for l in levels {
            for b in l.blocks {
                h = b(h)
            }
            if let d = l.downsample {
                h = d(h)
            }
        }
        let n = normOut(h)
        h = convOut(silu(n))
        // quant_conv, as a matmul over the channel axis
        let c = h.dim(1)
        let flat = h.transposed(0, 2, 3, 4, 1).reshaped([-1, c])
        let m = (matmul(flat, quantConv.T) + quantConvBias)
            .reshaped([h.dim(0), h.dim(2), h.dim(3), h.dim(4), quantConv.dim(0)])
            .transposed(0, 4, 1, 2, 3)
        return m
    }

    /// Pixels `[B, 3, T, H, W]` in [-1, 1] -> normalized latents `[B, 24, T_lat, H/16, W/16]`.
    ///
    /// This is the single-shot path: no spatial tiling and no temporal
    /// chunking. Both of those are chunking strategies over this same function
    /// — see ``tiledMoments(_:)`` and ``temporalMoments(_:)`` — and ``encode(_:)``
    /// is what routes between them.
    /// `[-1,1] -> [0,1] -> ImageNet mean/std`. The encoder never sees raw
    /// signed pixels.
    func normalizePixels(_ pixels: MLXArray) -> MLXArray {
        let mean3 = MLXArray(Self.pixelMean).reshaped([1, 3, 1, 1, 1])
        let std3 = MLXArray(Self.pixelStd).reshaped([1, 3, 1, 1, 1])
        return ((pixels.asType(.float32) + 1.0) * 0.5 - mean3) / std3
    }

    func encodeSingleShot(_ pixels: MLXArray, seed: UInt64 = 42) -> MLXArray {
        sampleMoments(moments(normalizePixels(pixels)), seed: seed)
    }

    /// Single frame in, single latent frame out — the `T == 1` path, which is
    /// exactly what a keyframe or a reference image needs.
    ///
    /// The reference truncates to the last latent frame here because the causal
    /// front padding manufactures leading frames that carry no information.
    func encodeImage(_ pixels: MLXArray, seed: UInt64 = 42) -> MLXArray {
        precondition(pixels.dim(2) == 1,
                     "encodeImage wants one frame, got \(pixels.dim(2)); "
                     + "multi-frame clips need the temporal chunking that is not ported")
        let z = encodeSingleShot(pixels, seed: seed)
        return z[0..., 0..., (z.dim(2) - 1) ..< z.dim(2), 0..., 0...]
    }

    /// `tiled_encode` — a grid of `tileSize` tiles, cross-faded in latent space.
    ///
    /// This is not an optimisation that can be skipped at small cost. Anything
    /// wider or taller than 256 px goes through it in the reference: at 864x480
    /// that is a 5x3 grid, fifteen full passes over the conv stack, and the
    /// seams are blended rather than butted. A single-shot pass over the whole
    /// frame produces different numbers everywhere, not just near the seams,
    /// because the causal and reflect padding land at different places.
    func tiledMoments(_ x: MLXArray) -> MLXArray {
        let h = x.dim(3), w = x.dim(4)
        let (yIdx, yLen, yOverlap) = VaeTiling.splitTiles(inputLen: h)
        let (xIdx, xLen, xOverlap) = VaeTiling.splitTiles(inputLen: w)

        var rows: [[MLXArray]] = []
        for (iPos, iLen) in zip(yIdx, yLen) {
            var row: [MLXArray] = []
            for (jPos, jLen) in zip(xIdx, xLen) {
                var t = VaeTiling.sliceDim(x, dim: 3, start: iPos, end: iPos + iLen)
                t = VaeTiling.sliceDim(t, dim: 4, start: jPos, end: jPos + jLen)
                row.append(moments(t))
            }
            rows.append(row)
        }

        let latY = yOverlap.map { $0 / VaeTiling.vaeRatio }
        let latX = xOverlap.map { $0 / VaeTiling.vaeRatio }
        var resultRows: [MLXArray] = []
        for i in rows.indices {
            var resultRow: [MLXArray] = []
            for j in rows[i].indices {
                var tile = rows[i][j]
                if i > 0 { tile = VaeTiling.blend(rows[i - 1][j], tile, blendExtent: latY[i - 1], dim: -2) }
                if j > 0 { tile = VaeTiling.blend(rows[i][j - 1], tile, blendExtent: latX[j - 1], dim: -1) }
                if i < rows.count - 1 {
                    tile = VaeTiling.sliceDim(tile, dim: -2, start: 0, end: tile.dim(-2) - latY[i])
                }
                if j < rows[i].count - 1 {
                    tile = VaeTiling.sliceDim(tile, dim: -1, start: 0, end: tile.dim(-1) - latX[j])
                }
                resultRow.append(tile)
            }
            resultRows.append(concatenated(resultRow, axis: -1))
        }
        return concatenated(resultRows, axis: -2)
    }

    /// `_adaptive_encode` — the reference constructs the VAE with `tiling=True`,
    /// so this is always the tiled call. `splitTiles` degenerates to one tile
    /// when the frame fits, which is why the small-frame case needs no branch.
    func adaptiveMoments(_ normalized: MLXArray) -> MLXArray {
        tiledMoments(normalized)
    }

    /// `encode_temporal` — the multi-frame path, as moments.
    ///
    /// Three steps, and each one is a place a port silently disagrees:
    ///
    /// 1. **Pad by repeating the last frame** up to a multiple of `clipLength`.
    ///    Zero-padding or edge-reflecting instead keeps every shape correct.
    /// 2. **Encode each clip independently.** The clips do not overlap and are
    ///    not blended — unlike the spatial tiles, and unlike `decode_temporal`,
    ///    which does overlap.
    /// 3. **Drop `tokenDrop` tokens off the tail** after the concatenation, not
    ///    per clip. Dropping per clip changes the temporal latent length.
    ///
    /// Input is already normalized; the caller owns the pixel statistics.
    func temporalMoments(_ normalized: MLXArray) -> MLXArray {
        let frames = normalized.dim(2)
        var x = normalized
        let pad = (Self.clipLength - frames % Self.clipLength) % Self.clipLength
        if pad > 0 {
            let last = VaeTiling.sliceDim(x, dim: 2, start: frames - 1, end: frames)
            x = concatenated([x] + Array(repeating: last, count: pad), axis: 2)
        }
        let chunks = x.dim(2) / Self.clipLength
        var z: [MLXArray] = []
        z.reserveCapacity(chunks)
        for i in 0 ..< chunks {
            let clip = VaeTiling.sliceDim(x, dim: 2,
                                          start: i * Self.clipLength,
                                          end: (i + 1) * Self.clipLength)
            z.append(adaptiveMoments(clip))
        }
        var out = concatenated(z, axis: 2)
        if Self.tokenDrop > 0 {
            out = VaeTiling.sliceDim(out, dim: 2, start: 0, end: out.dim(2) - Self.tokenDrop)
        }
        return out
    }

    /// `[-1, 1]` pixels -> the normalized-pixel tensor the clips actually see.
    func normalized(_ pixels: MLXArray) -> MLXArray { normalizePixels(pixels) }

    /// Samples the released condition posterior with its fixed seed, rounds
    /// through float16, then applies the checkpoint's latent normalization.
    func sampleMoments(_ m: MLXArray, seed: UInt64 = 42) -> MLXArray {
        let mean = m[0..., 0 ..< Self.zChannels, 0..., 0..., 0...]
        let logVariance = clip(
            m[0..., Self.zChannels ..< (2 * Self.zChannels), 0..., 0..., 0...],
            min: -30.0,
            max: 20.0)
        let noise = MLXRandom.normal(mean.shape, key: MLXRandom.key(seed))
        let sampled = (mean + exp(0.5 * logVariance) * noise)
            .asType(.float16)
            .asType(.float32)
        return (sampled - latentsMean.reshaped([1, Self.zChannels, 1, 1, 1]))
             / latentsStd.reshaped([1, Self.zChannels, 1, 1, 1])
    }

    /// Pixels in `[-1, 1]` -> normalized latents, for any frame count.
    ///
    /// One frame keeps the last latent frame (the causal front pad manufactures
    /// leading frames that carry no information); more than one goes through
    /// ``temporalMoments(_:)``. Tiling is the reference's normal path, not a
    /// low-memory fallback, so both branches tile.
    func encode(_ pixels: MLXArray, seed: UInt64 = 42) -> MLXArray {
        let normalized = normalizePixels(pixels)
        if pixels.dim(2) == 1 {
            let z = sampleMoments(adaptiveMoments(normalized), seed: seed)
            return z[0..., 0..., (z.dim(2) - 1) ..< z.dim(2), 0..., 0...]
        }
        return sampleMoments(temporalMoments(normalized), seed: seed)
    }
}


struct VaeRMSNorm {
    let weight: MLXArray?
    let eps: Float

    init(weight: MLXArray? = nil, eps: Float = 1e-5) {
        self.weight = weight
        self.eps = eps
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let f = x.asType(.float32)
        let n = f * rsqrt(mean(f * f, axis: -1, keepDims: true) + eps)
        if let weight {
            return (n * weight.asType(.float32)).asType(x.dtype)
        }
        return n.asType(x.dtype)
    }
}

struct VaeLayerNorm {
    let weight: MLXArray
    let bias: MLXArray
    let eps: Float

    init(weight: MLXArray, bias: MLXArray, eps: Float = 1e-5) {
        self.weight = weight
        self.bias = bias
        self.eps = eps
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let f = x.asType(.float32)
        let mu = mean(f, axis: -1, keepDims: true)
        let diff = f - mu
        let variance = mean(diff * diff, axis: -1, keepDims: true)
        let n = diff * rsqrt(variance + eps)
        return (n * weight.asType(.float32) + bias.asType(.float32)).asType(x.dtype)
    }
}

struct RotaryEmbeddingND {
    let invFreq: MLXArray
    let angleScale: Float = 2.0 * Float.pi

    init(dim: Int, theta: Float = 100.0) {
        let step = 6.0 / Float(dim)
        var sValues: [Float] = []
        var curr: Float = 0.0
        while curr < 1.0 - 1e-6 {
            sValues.append(curr)
            curr += step
        }
        self.invFreq = 1.0 / pow(MLXArray(theta), MLXArray(sValues))
    }

    func callAsFunction(_ imgIds: MLXArray) -> MLXArray {
        let B = imgIds.dim(0)
        let S = imgIds.dim(1)
        let imgIdsExpanded = imgIds.expandedDimensions(axis: -1)
        let invFreqReshaped = invFreq.reshaped([1, 1, 1, invFreq.dim(0)])
        let angles = imgIdsExpanded.asType(.float32) * angleScale * invFreqReshaped
        let anglesFlat = angles.reshaped([B, S, angles.dim(2) * angles.dim(3)])

        let c = cos(anglesFlat)
        let s = sin(anglesFlat)

        let table = stacked([c, -s, s, c], axis: -1)
        return table.reshaped([B, S, 1, anglesFlat.dim(2), 2, 2])
    }
}

struct VaeAttention {
    let normQ: VaeRMSNorm
    let normK: VaeRMSNorm
    let toQkvWeight: MLXArray
    let toQkvBias: MLXArray
    let toOutWeight: MLXArray
    let toOutBias: MLXArray
    let heads: Int
    let dimHead: Int

    func callAsFunction(_ x: MLXArray, rotaryPosEmb: MLXArray?) -> MLXArray {
        let B = x.dim(0)
        let S = x.dim(1)

        let qkv = matmul(x, toQkvWeight.T) + toQkvBias
        let reshaped = qkv.reshaped([B, S, heads, 3 * dimHead])

        let query = reshaped[0..., 0..., 0..., 0 ..< dimHead]
        let key = reshaped[0..., 0..., 0..., dimHead ..< (2 * dimHead)]
        let value = reshaped[0..., 0..., 0..., (2 * dimHead)...]

        var q = normQ(query)
        var k = normK(key)

        if let table = rotaryPosEmb {
            let half = table.dim(-3)
            let rot = half * 2

            let c = table[0..., 0..., 0, 0..., 0, 0].expandedDimensions(axis: 2)
            let negS = table[0..., 0..., 0, 0..., 0, 1].expandedDimensions(axis: 2)
            let s = table[0..., 0..., 0, 0..., 1, 0].expandedDimensions(axis: 2)
            let c2 = table[0..., 0..., 0, 0..., 1, 1].expandedDimensions(axis: 2)

            let qA = q[0..., 0..., 0..., 0 ..< half]
            let qB = q[0..., 0..., 0..., half ..< rot]
            let qRa = c * qA + negS * qB
            let qRb = s * qA + c2 * qB
            let qRotated = concatenated([qRa, qRb], axis: -1)
            q = concatenated([qRotated, q[0..., 0..., 0..., rot...]], axis: -1)

            let kA = k[0..., 0..., 0..., 0 ..< half]
            let kB = k[0..., 0..., 0..., half ..< rot]
            let kRa = c * kA + negS * kB
            let kRb = s * kA + c2 * kB
            let kRotated = concatenated([kRa, kRb], axis: -1)
            k = concatenated([kRotated, k[0..., 0..., 0..., rot...]], axis: -1)
        }

        let qh = q.transposed(0, 2, 1, 3)
        let kh = k.transposed(0, 2, 1, 3)
        let vh = value.transposed(0, 2, 1, 3)

        let scale = 1.0 / Float(dimHead).squareRoot()
        let out = MLXFast.scaledDotProductAttention(
            queries: qh, keys: kh, values: vh,
            scale: scale, mask: nil
        )

        let merged = out.transposed(0, 2, 1, 3).reshaped([B, S, heads * dimHead])
        return matmul(merged, toOutWeight.T) + toOutBias
    }
}

struct VaeFeedForward {
    let w1Weight: MLXArray
    let w1Bias: MLXArray
    let w2Weight: MLXArray
    let w2Bias: MLXArray

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let h = matmul(x, w1Weight.T) + w1Bias
        let innerDim = h.dim(-1) / 2
        let gate = h[0..., 0..., 0 ..< innerDim]
        let up = h[0..., 0..., innerDim...]
        return matmul(silu(gate) * up, w2Weight.T) + w2Bias
    }
}

struct VaeTransformerBlock {
    let norm1: VaeRMSNorm
    let norm2: VaeRMSNorm
    let attn: VaeAttention
    let ff: VaeFeedForward
    let scale1: MLXArray
    let scale2: MLXArray

    func callAsFunction(_ x: MLXArray, rotaryPosEmb: MLXArray?) -> MLXArray {
        let h1 = norm1(x)
        let x1 = x + attn(h1, rotaryPosEmb: rotaryPosEmb) * scale1
        let h2 = norm2(x1)
        return x1 + ff(h2) * scale2
    }
}

struct ViT3DDecoder {
    let patchSize: Int = 16
    let patchSizeT: Int = 4
    let outChannels: Int = 3
    let numRegisterTokens: Int = 4

    let posEmbed: RotaryEmbeddingND
    let xEmbedderWeight: MLXArray
    let xEmbedderBias: MLXArray
    let registerTokens: MLXArray
    let normOut: VaeLayerNorm
    let projOutWeight: MLXArray
    let projOutBias: MLXArray
    let blocks: [VaeTransformerBlock]

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let B = x.dim(0)
        let C = x.dim(1)
        let latentT = x.dim(2)
        let latentH = x.dim(3)
        let latentW = x.dim(4)

        let flattened = x.reshaped([B, C, -1])
        let transposed = flattened.transposed(0, 2, 1)

        var h = matmul(transposed, xEmbedderWeight.T) + xEmbedderBias

        let numPatches = h.dim(1)
        let numSuffix = 1 + numRegisterTokens

        let regExpanded = broadcast(registerTokens, to: [B, numRegisterTokens, registerTokens.dim(-1)])
        let zeroSuffix = MLXArray.zeros([B, 1, h.dim(-1)], dtype: h.dtype)

        h = concatenated([h, regExpanded, zeroSuffix], axis: 1)

        let imgIds = createTokenIds(latentT: latentT, latentH: latentH, latentW: latentW, dtype: h.dtype)
        let imgIdsExpanded = broadcast(imgIds, to: [B, imgIds.dim(1), imgIds.dim(2)])
        let suffixIds = MLXArray.zeros([B, numSuffix, 3], dtype: h.dtype)
        let imgIdsFull = concatenated([imgIdsExpanded, suffixIds], axis: 1)

        let rotaryPosEmb = posEmbed(imgIdsFull)

        for block in blocks {
            h = block(h, rotaryPosEmb: rotaryPosEmb)
        }

        var output = matmul(normOut(h), projOutWeight.T) + projOutBias

        output = output[0..., 0 ..< numPatches, 0...]

        output = output.reshaped([
            B, latentT, latentH, latentW,
            outChannels, patchSizeT, patchSize, patchSize
        ])

        output = output.transposed(0, 4, 1, 5, 2, 6, 3, 7)

        output = output.reshaped([
            B, outChannels,
            latentT * patchSizeT,
            latentH * patchSize,
            latentW * patchSize
        ])

        return output
    }

    private func createTokenIds(latentT: Int, latentH: Int, latentW: Int, dtype: DType) -> MLXArray {
        func makeCoords(dimSize: Int) -> MLXArray {
            let coords = (MLXArray(0 ..< dimSize).asType(dtype) + 0.5) / Float(dimSize)
            return 2.0 * coords - 1.0
        }
        let coordsT = makeCoords(dimSize: latentT)
        let coordsH = makeCoords(dimSize: latentH)
        let coordsW = makeCoords(dimSize: latentW)

        let gridT = broadcast(coordsT.reshaped([latentT, 1, 1]), to: [latentT, latentH, latentW])
        let gridH = broadcast(coordsH.reshaped([1, latentH, 1]), to: [latentT, latentH, latentW])
        let gridW = broadcast(coordsW.reshaped([1, 1, latentW]), to: [latentT, latentH, latentW])

        let coords = stacked([gridT, gridH, gridW], axis: -1)
        return coords.reshaped([1, latentT * latentH * latentW, 3])
    }
}

final class H3VisualVAE {
    let url: URL?
    private let postQuantConvWeight: MLXArray
    private let postQuantConvBias: MLXArray
    private let decoder: ViT3DDecoder

    let latentsMean: MLXArray
    let latentsStd: MLXArray

    let pixelMean = MLXArray(IMAGENET_MEAN).reshaped([1, 3, 1, 1, 1])
    let pixelStd = MLXArray(IMAGENET_STD).reshaped([1, 3, 1, 1, 1])

    static let IMAGENET_MEAN: [Float] = [0.485, 0.456, 0.406]
    static let IMAGENET_STD: [Float] = [0.229, 0.224, 0.225]

    private init(weights: [String: MLXArray], sourceURL: URL?) throws {
        self.url = sourceURL
        let w = weights

        func get(_ name: String) throws -> MLXArray {
            guard let a = w[name] else {
                throw H3BaseWeights.Error.missing(name)
            }
            return a
        }

        self.postQuantConvWeight = try get("post_quant_conv.weight")
        self.postQuantConvBias = try get("post_quant_conv.bias")
        self.latentsMean = try get("latents_mean")
        self.latentsStd = try get("latents_std")

        let posEmbed = RotaryEmbeddingND(dim: 48, theta: 100.0)
        let xEmbedderWeight = try get("decoder.x_embedder.weight")
        let xEmbedderBias = try get("decoder.x_embedder.bias")
        let registerTokens = try get("decoder.register_tokens")
        let normOutWeight = try get("decoder.norm_out.weight")
        let normOutBias = try get("decoder.norm_out.bias")
        let normOut = VaeLayerNorm(weight: normOutWeight, bias: normOutBias, eps: 1e-5)
        let projOutWeight = try get("decoder.proj_out.weight")
        let projOutBias = try get("decoder.proj_out.bias")

        var blocks: [VaeTransformerBlock] = []
        for i in 0 ..< 36 {
            let p = "decoder.transformer_blocks.\(i)."
            let norm1 = VaeRMSNorm(weight: try get(p + "norm1.weight"), eps: 1e-5)
            let norm2 = VaeRMSNorm(weight: try get(p + "norm2.weight"), eps: 1e-5)
            let scale1 = try get(p + "scale1")
            let scale2 = try get(p + "scale2")

            let toQkvWeight = try get(p + "attn.to_qkv.weight")
            let toQkvBias = try get(p + "attn.to_qkv.bias")
            let toOutWeight = try get(p + "attn.to_out.weight")
            let toOutBias = try get(p + "attn.to_out.bias")

            let attn = VaeAttention(
                normQ: VaeRMSNorm(eps: 1e-5),
                normK: VaeRMSNorm(eps: 1e-5),
                toQkvWeight: toQkvWeight, toQkvBias: toQkvBias,
                toOutWeight: toOutWeight, toOutBias: toOutBias,
                heads: 32, dimHead: 64
            )

            let ff = VaeFeedForward(
                w1Weight: try get(p + "ff.w1.weight"),
                w1Bias: try get(p + "ff.w1.bias"),
                w2Weight: try get(p + "ff.w2.weight"),
                w2Bias: try get(p + "ff.w2.bias")
            )

            blocks.append(VaeTransformerBlock(
                norm1: norm1, norm2: norm2,
                attn: attn, ff: ff,
                scale1: scale1, scale2: scale2
            ))
        }

        self.decoder = ViT3DDecoder(
            posEmbed: posEmbed,
            xEmbedderWeight: xEmbedderWeight,
            xEmbedderBias: xEmbedderBias,
            registerTokens: registerTokens,
            normOut: normOut,
            projOutWeight: projOutWeight,
            projOutBias: projOutBias,
            blocks: blocks
        )
    }

    convenience init(weights: [String: MLXArray]) throws {
        try self.init(weights: weights, sourceURL: nil)
    }

    convenience init(url: URL) throws {
        try self.init(
            weights: H3Loader.loadWeights(from: url),
            sourceURL: url)
    }

    convenience init(hub: HubApi, configuration: H3Configuration) throws {
        try self.init(
            weights: H3Loader.loadWeights(
                hub: hub,
                configuration: configuration,
                key: .videoVAEWeights))
    }

    func postQuantConv(_ z: MLXArray) -> MLXArray {
        let zT = z.transposed(0, 2, 3, 4, 1)
        var out = matmul(zT, postQuantConvWeight.reshaped([24, 24]).T)
        out = out + postQuantConvBias
        return out.transposed(0, 4, 1, 2, 3)
    }

    func decodePixels(_ z: MLXArray) -> MLXArray {
        let pq = postQuantConv(z)
        return decoder(pq)
    }

    func splitTiles(inputLen: Int, tileSize: Int = 256, tileOverlapMin: Int = 64, vaeRatio: Int = 16) -> (starts: [Int], lengths: [Int], overlaps: [Int]) {
        if tileSize >= inputLen {
            return ([0], [inputLen], [])
        }
        var N = Int(ceil(Double(inputLen) / Double(tileSize)))
        var overlaps: [Int] = []
        while true {
            overlaps = Array(repeating: tileOverlapMin, count: N - 1)
            let sumOverlaps = overlaps.reduce(0, +)
            let remaining = tileSize * N - sumOverlaps - inputLen
            if remaining < 0 {
                N += 1
            } else {
                break
            }
        }
        let remaining = tileSize * N - overlaps.reduce(0, +) - inputLen
        let remainingUnits = remaining / vaeRatio
        for i in 0 ..< remainingUnits {
            overlaps[i % (N - 1)] += vaeRatio
        }
        var tileStartIdx = [0]
        for i in 0 ..< (N - 1) {
            tileStartIdx.append(tileStartIdx.last! + tileSize - overlaps[i])
        }
        return (tileStartIdx, Array(repeating: tileSize, count: N), overlaps)
    }

    func blend(_ a: MLXArray, _ b: MLXArray, blendExtent: Int, dim: Int) -> MLXArray {
        let ndim = a.ndim
        // Callers pass -1 and -2. MLXArray.dim() and sliceDim() both accept
        // negative axes; a Swift Array subscript does not, and indexing
        // weightShape[-1] traps. Normalise once, here.
        let axis = dim < 0 ? ndim + dim : dim
        precondition(axis >= 0 && axis < ndim, "blend axis \(dim) outside 0..<\(ndim)")
        let actualExtent = min(a.dim(axis), b.dim(axis), blendExtent)
        if actualExtent <= 0 {
            return b
        }
        let positions = MLXArray(0 ..< actualExtent).asType(b.dtype)
        let weightA = 1.0 - (positions / Float(actualExtent))
        let weightB = positions / Float(actualExtent)

        var weightShape = Array(repeating: 1, count: ndim)
        weightShape[axis] = actualExtent
        let wA = weightA.reshaped(weightShape)
        let wB = weightB.reshaped(weightShape)

        let sliceA = sliceDim(a, dim: axis, start: a.dim(axis) - actualExtent, end: a.dim(axis))
        let sliceB = sliceDim(b, dim: axis, start: 0, end: actualExtent)

        let blended = sliceA * wA + sliceB * wB

        if actualExtent < b.dim(axis) {
            let sliceBRest = sliceDim(b, dim: axis, start: actualExtent, end: b.dim(axis))
            return concatenated([blended, sliceBRest], axis: axis)
        }
        return blended
    }

    private func sliceDim(_ array: MLXArray, dim: Int, start: Int, end: Int) -> MLXArray {
        let size = array.dim(dim)
        let s = max(0, min(size, start))
        let e = max(0, min(size, end))
        let actualDim = dim < 0 ? array.ndim + dim : dim

        var indices: [any MLXArrayIndex] = []
        for i in 0 ..< array.ndim {
            if i == actualDim {
                indices.append(s ..< e)
            } else {
                indices.append(0 ..< array.dim(i))
            }
        }
        return array[indices]
    }

    func tiledDecode(_ z: MLXArray) -> MLXArray {
        let vaeRatio = 16
        let height = z.dim(-2) * vaeRatio
        let width = z.dim(-1) * vaeRatio

        let (yIdx, yLen, yOverlap) = splitTiles(inputLen: height)
        let (xIdx, xLen, xOverlap) = splitTiles(inputLen: width)

        var rowTensors: [MLXArray] = []
        var rowTails: [MLXArray] = []

        for (i, (iPos, iLen)) in zip(yIdx, yLen).enumerated() {
            let zi = iPos / vaeRatio
            let zl = iLen / vaeRatio
            var newTails: [MLXArray] = []
            var leftTail: MLXArray? = nil
            var rowTiles: [MLXArray] = []

            for (j, (jPos, jLen)) in zip(xIdx, xLen).enumerated() {
                let zj = jPos / vaeRatio
                let zw = jLen / vaeRatio

                let zSlice = z[0..., 0..., 0..., zi ..< (zi + zl), zj ..< (zj + zw)]
                var tile = decodePixels(zSlice)

                if i < yIdx.count - 1 {
                    let overlapY = yOverlap[i]
                    let start = tile.dim(-2) - overlapY
                    let tail = sliceDim(tile, dim: -2, start: start, end: tile.dim(-2))
                    newTails.append(tail)
                }
                var nextLeftTail: MLXArray? = nil
                if j < xIdx.count - 1 {
                    let overlapX = xOverlap[j]
                    let start = tile.dim(-1) - overlapX
                    nextLeftTail = sliceDim(tile, dim: -1, start: start, end: tile.dim(-1))
                }

                if i > 0 {
                    tile = blend(rowTails[j], tile, blendExtent: yOverlap[i - 1], dim: -2)
                }
                if j > 0, let left = leftTail {
                    tile = blend(left, tile, blendExtent: xOverlap[j - 1], dim: -1)
                }

                leftTail = nextLeftTail

                if i < yIdx.count - 1 {
                    tile = sliceDim(tile, dim: -2, start: 0, end: tile.dim(-2) - yOverlap[i])
                }
                if j < xIdx.count - 1 {
                    tile = sliceDim(tile, dim: -1, start: 0, end: tile.dim(-1) - xOverlap[j])
                }

                rowTiles.append(tile)
            }

            rowTails = newTails
            let rowTensor = concatenated(rowTiles, axis: -1)
            rowTensors.append(rowTensor)
        }

        return concatenated(rowTensors, axis: -2)
    }

    func decodeTemporalPadFrames(zLen: Int, padTokens: Int) -> Int {
        if padTokens <= 0 { return 0 }
        let clipLength = 17
        let vaeRatioT = 4
        let tokensChunkSize = 5
        let intraTail = clipLength % vaeRatioT
        // H3's fixed 17-frame clip has a one-frame intra-chunk tail under the
        // VAE's 4x temporal ratio. Keep the arithmetic named because it is the
        // reference contract; there is no alternate zero-tail architecture in
        // this model.
        let zLenBeforePad = zLen - padTokens
        var sum = 0
        for k in 0 ..< padTokens {
            if (zLenBeforePad + k) % tokensChunkSize == 0 {
                sum += intraTail
            } else {
                sum += vaeRatioT
            }
        }
        return sum
    }

    func decodeTemporalFramePlan(zLen: Int, numChunks: Int, padTokens: Int) -> Int {
        let tokensChunkSize = 5
        let vaeRatioT = 4
        let tokenOverlap = 2
        let framePrePadding = 3
        let chunkDec = tokensChunkSize * vaeRatioT
        let tokenDrop = 3
        let splitCount = (tokenDrop > 0 ? 1 : 0) + 1

        var totalFrames = 0
        var finalOverlapFrames = 0

        for i in 0 ..< numChunks {
            let tStartIdx = i * tokensChunkSize
            let tEndIdx = tStartIdx + tokensChunkSize + tokenOverlap
            let clipTokenLen = max(0, min(tEndIdx, zLen) - min(tStartIdx, zLen))
            let clipFrameLen = clipTokenLen * vaeRatioT

            for j in 0 ..< splitCount {
                let fStartIdx = j * chunkDec
                let fEndIdx = min(fStartIdx + chunkDec, clipFrameLen)
                let chunkFrames = max(0, fEndIdx - fStartIdx - framePrePadding)
                if j == 0 {
                    totalFrames += chunkFrames
                } else {
                    finalOverlapFrames = chunkFrames
                }
            }
        }

        totalFrames += finalOverlapFrames
        return totalFrames - decodeTemporalPadFrames(zLen: zLen, padTokens: padTokens)
    }

    func decodeTemporal(_ z: MLXArray) -> MLXArray {
        let tokensChunkSize = 5
        let tokenOverlap = 2
        let frameOverlap = 5
        let framePrePadding = 3
        let chunkDec = tokensChunkSize * 4
        let tokenDrop = 3
        let splitCount = (tokenDrop > 0 ? 1 : 0) + 1

        var z = z
        let pseudoTotalTokens = z.dim(2) + tokenDrop
        var padTokens = 0
        let remainder = pseudoTotalTokens % tokensChunkSize
        if remainder != 0 {
            padTokens = tokensChunkSize - remainder
        }
        var numChunks = (pseudoTotalTokens + padTokens) / tokensChunkSize - (tokenDrop > 0 ? 1 : 0)
        if numChunks < 1 {
            padTokens += tokensChunkSize
            numChunks += 1
        }

        if padTokens > 0 {
            let lastZ = z[0..., 0..., (z.dim(2) - 1) ..< z.dim(2), 0..., 0...]
            let padZ = broadcast(lastZ, to: [z.dim(0), z.dim(1), padTokens, z.dim(3), z.dim(4)])
            z = concatenated([z, padZ], axis: 2)
        }

        let outputFrames = decodeTemporalFramePlan(zLen: z.dim(2), numChunks: numChunks, padTokens: padTokens)

        var partsToConcat: [MLXArray] = []
        var totalWrittenFrames = 0

        func writePart(_ part: MLXArray) {
            let partFrames = part.dim(2)
            if partFrames <= 0 { return }
            let copyFrames = min(partFrames, max(0, outputFrames - totalWrittenFrames))
            if copyFrames > 0 {
                let sliced = sliceDim(part, dim: 2, start: 0, end: copyFrames)
                partsToConcat.append(sliced)
                totalWrittenFrames += copyFrames
            }
        }

        var decOverlap: MLXArray? = nil

        for i in 0 ..< numChunks {
            let tStartIdx = i * tokensChunkSize
            let tEndIdx = tStartIdx + tokensChunkSize + tokenOverlap
            let clipZ = z[0..., 0..., tStartIdx ..< tEndIdx, 0..., 0...]

            let clipDec = tiledDecode(clipZ)

            for j in 0 ..< splitCount {
                let fStartIdx = j * chunkDec
                let fEndIdx = min(fStartIdx + chunkDec, clipDec.dim(2))
                var clipDecChunk = sliceDim(clipDec, dim: 2, start: fStartIdx, end: fEndIdx)
                clipDecChunk = sliceDim(clipDecChunk, dim: 2, start: framePrePadding, end: clipDecChunk.dim(2))

                if j == 0 {
                    if let overlap = decOverlap {
                        clipDecChunk = blend(overlap, clipDecChunk, blendExtent: frameOverlap, dim: 2)
                        decOverlap = nil
                    }
                    writePart(clipDecChunk)
                } else {
                    decOverlap = clipDecChunk
                }
            }
        }

        if let overlap = decOverlap {
            writePart(overlap)
            decOverlap = nil
        }

        return concatenated(partsToConcat, axis: 2)
    }

    func decode(_ z: MLXArray) -> MLXArray {
        let meanVal = latentsMean.reshaped([1, 24, 1, 1, 1])
        let stdVal = latentsStd.reshaped([1, 24, 1, 1, 1])
        let scaledZ = z * stdVal + meanVal

        var dec: MLXArray
        if z.dim(2) == 1 {
            dec = tiledDecode(scaledZ)
            dec = sliceDim(dec, dim: 2, start: dec.dim(2) - 1, end: dec.dim(2))
        } else {
            dec = decodeTemporal(scaledZ)
        }

        let fDec = dec.asType(.float32)
        let out = (fDec * pixelStd.asType(.float32) + pixelMean.asType(.float32))
        let clamped = minimum(maximum(out, 0.0), 1.0)
        return clamped * 2.0 - 1.0
    }
}
