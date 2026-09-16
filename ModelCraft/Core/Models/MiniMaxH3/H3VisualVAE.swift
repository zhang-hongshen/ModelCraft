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


/// The Visual VAE, both directions: latents in, pixels out.
///
/// A `Module` whose parts are declared under the checkpoint's own names and
/// filled by ``H3Loader/loadVisualVAE(hub:configuration:)`` from one read of the
/// file. The 36-block stack is not part of the declaration —
/// ``H3VisualVAEDecoder`` reads each block as the decode reaches it.
final class H3VisualVAE: Module {
    let configuration: H3Configuration
    /// This component's own dimensions, out of the one configuration.
    var config: H3VideoVAEConfiguration { configuration.videoVAE }

    @ModuleInfo(key: "post_quant_conv") var postQuantConv: H3Projection
    @ModuleInfo var encoder: H3VisualVAEEncoder
    @ModuleInfo var decoder: H3VisualVAEDecoder
    
    /// The latent normalization, which this checkpoint keeps in `vae/config.json`
    /// rather than among its weights. Swift arrays, not `MLXArray`s: a `Module`
    /// walks its `MLXArray` ivars as the weights a load fills.
    let latentsMean: [Float]
    let latentsStd: [Float]
    

    /// ImageNet statistics, the VAE's own convention. Not from the checkpoint, so
    /// computed rather than stored: a `Module` walks its `MLXArray` ivars as the
    /// weights a load fills, and a constant would be demanded from the checkpoint
    /// like one.
    var pixelMean: MLXArray { MLXArray(Self.IMAGENET_MEAN).reshaped([1, 3, 1, 1, 1]) }
    var pixelStd: MLXArray { MLXArray(Self.IMAGENET_STD).reshaped([1, 3, 1, 1, 1]) }

    static let IMAGENET_MEAN: [Float] = [0.485, 0.456, 0.406]
    static let IMAGENET_STD: [Float] = [0.229, 0.224, 0.225]

    /// The declaration, with every parameter present but unread. What fills it is
    /// ``H3Loader/loadVisualVAE(hub:configuration:)``, which builds this and hands
    /// it one read of the file.
    ///
    /// Both directions are owned here rather than by the caller: it is one
    /// checkpoint, read once, and a reference-conditioned render needs the
    /// encoder's pass and then the decoder's.
    init(hub: HubApi, configuration: H3Configuration) {
        self.configuration = configuration
        self.latentsMean = configuration.videoVAE.latentsMean
        self.latentsStd = configuration.videoVAE.latentsStd
        self.encoder = H3VisualVAEEncoder(configuration: configuration.videoVAE)
        // A 1x1x1 convolution, stored with its kernel axes; the forward flattens
        // it because the stride equals the kernel.
        let c = configuration.videoVAE
        self._postQuantConv.wrappedValue = H3Projection(
            weightShape: Array(repeating: c.latentChannels, count: 2) + [1, 1, 1],
            biasShape: [c.latentChannels])
        self._decoder.wrappedValue = H3VisualVAEDecoder(
            hub: hub, configuration: configuration)
    }

    /// `post_quant_conv` is a per-position mix over the 24 latent channels, so it
    /// runs as a matmul on the last axis rather than as a convolution.
    private func mixLatents(_ z: MLXArray) -> MLXArray {
        let zT = z.transposed(0, 2, 3, 4, 1)
        let out = matmul(zT, postQuantConv.weight.reshaped(
            [config.latentChannels, config.latentChannels]).T) + postQuantConv.bias
        return out.transposed(0, 4, 1, 2, 3)
    }

    func decodePixels(_ z: MLXArray) throws -> MLXArray {
        try decoder(mixLatents(z))
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

    func tiledDecode(_ z: MLXArray) throws -> MLXArray {
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
                var tile = try decodePixels(zSlice)

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

    func decodeTemporal(_ z: MLXArray) throws -> MLXArray {
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

            let clipDec = try tiledDecode(clipZ)

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

    /// A keyframe, a reference image or a reference video through the encoder
    /// half, on its way to a latent.
    ///
    /// This type is the decoder by nature and the encoder by delegation; callers
    /// see one component either way.
    func encode(_ pixels: MLXArray, seed: UInt64 = 42) throws -> MLXArray {
        try encoder(pixels, seed: seed)
    }

    func decode(_ z: MLXArray) throws -> MLXArray {
        let meanVal = MLXArray(latentsMean).reshaped([1, config.latentChannels, 1, 1, 1])
        let stdVal = MLXArray(latentsStd).reshaped([1, config.latentChannels, 1, 1, 1])
        let scaledZ = z * stdVal + meanVal

        var dec: MLXArray
        if z.dim(2) == 1 {
            dec = try tiledDecode(scaledZ)
            dec = sliceDim(dec, dim: 2, start: dec.dim(2) - 1, end: dec.dim(2))
        } else {
            dec = try decodeTemporal(scaledZ)
        }

        let fDec = dec.asType(.float32)
        let out = (fDec * pixelStd.asType(.float32) + pixelMean.asType(.float32))
        let clamped = minimum(maximum(out, 0.0), 1.0)
        return clamped * 2.0 - 1.0
    }
}

/// The encoder half: pixels to latents, the direction a reference-conditioned
/// render reads.
///
/// A `Module`, so that ``H3VisualVAE`` — which owns it — can have the loader fill
/// it in the same read of the file as the decoder.
final class H3VisualVAEEncoder: Module {
    /// ImageNet statistics. Pixels arrive in [-1, 1], are mapped to [0, 1], then
    /// standardised by these — the encoder never sees the raw range.
    static let pixelMean: [Float] = [0.485, 0.456, 0.406]
    static let pixelStd: [Float] = [0.229, 0.224, 0.225]

    /// Above this on either spatial axis the reference tiles. A runtime choice,
    /// not a dimension of the checkpoint, so it is not in the configuration.
    static let tileSize = 256

    /// This component's own dimensions, out of the one configuration.
    let config: H3VideoVAEConfiguration
    /// The latent normalization the encoder inverts on its way out.
    private let latentsMean: [Float]
    private let latentsStd: [Float]

    /// Everything the forward pass reads: 0.716 GB, declared under the
    /// checkpoint's names and filled by ``H3Loader/loadVisualVAE(hub:configuration:)``.
    @ModuleInfo(key: "conv_in") var convIn: CausalConv3d
    @ModuleInfo(key: "down_blocks") var levels: [H3VisualEncoderDownBlock]
    @ModuleInfo(key: "norm_out") var normOut: TemporalIsolatedGroupNorm
    @ModuleInfo(key: "conv_out") var convOut: CausalConv3d
    /// `quant_conv` splits the encoder's 48 output channels into the 24 latent
    /// means and the 24 deviations. Held as a weight and a bias rather than as a
    /// convolution because it is used as a channel matmul.
    @ModuleInfo(key: "quant_conv") var quantConv: H3Projection

    /// The declaration, with every parameter present but unread.
    ///
    /// The channel plan is the checkpoint's, and its shapes confirm it: each
    /// level's first resnet widens from the level before it — 128, 256, 512 —
    /// which is exactly where the export carries a `conv_shortcut`.
    init(configuration config: H3VideoVAEConfiguration) {
        self.config = config
        self.latentsMean = config.latentsMean
        self.latentsStd = config.latentsStd

        let mid = config.blockOutChannels.map { config.blockOutChannels[0] * $0 }
        let inputs = [mid[0]] + mid.dropLast()
        let quant = 2 * config.latentChannels

        self._convIn.wrappedValue = CausalConv3d(
            weightShape: [mid[0], config.inChannels, 3, 3, 3],
            biasShape: [mid[0]], padding: (1, 1, 1))
        self._levels.wrappedValue = (0 ..< config.blockOutChannels.count).map { i in
            H3VisualEncoderDownBlock(inChannels: inputs[i], midChannels: mid[i],
                              timeStride: config.temporalDownsampleFactors[i], spaceStride: config.spatialDownsampleFactors[i],
                              numResBlocks: config.layersPerBlock)
        }
        self._normOut.wrappedValue = TemporalIsolatedGroupNorm(dimensions: mid[mid.count - 1])
        self._convOut.wrappedValue = CausalConv3d(
            weightShape: [quant, mid[mid.count - 1], 3, 3, 3],
            biasShape: [quant], padding: (1, 1, 1))
        self._quantConv.wrappedValue = H3Projection(
            weightShape: [quant, quant, 1, 1, 1], biasShape: [quant])
    }

    func moments(_ x: MLXArray) throws -> MLXArray {
        var h = convIn(x)
        for l in levels {
            for b in l.blocks {
                h = b(h)
            }
            if let d = l.downsampler {
                h = d(h)
            }
        }
        let n = normOut(h)
        h = convOut(silu(n))
        // quant_conv, as a matmul over the channel axis
        let c = h.dim(1)
        let flat = h.transposed(0, 2, 3, 4, 1).reshaped([-1, c])
        let m = (matmul(flat, quantConv.weight.reshaped(
                     [2 * config.latentChannels, 2 * config.latentChannels]).T) + quantConv.bias)
            .reshaped([h.dim(0), h.dim(2), h.dim(3), h.dim(4), quantConv.weight.dim(0)])
            .transposed(0, 4, 1, 2, 3)
        return m
    }

    /// Pixels `[B, 3, T, H, W]` in [-1, 1] -> normalized latents `[B, 24, T_lat, H/16, W/16]`.
    ///
    /// This is the single-shot path: no spatial tiling and no temporal
    /// chunking. Both of those are chunking strategies over this same function
    /// — see ``tiledMoments(_:)`` and ``temporalMoments(_:)`` — and
    /// ``callAsFunction(_:seed:)``
    /// is what routes between them.
    /// `[-1,1] -> [0,1] -> ImageNet mean/std`. The encoder never sees raw
    /// signed pixels.
    func normalizePixels(_ pixels: MLXArray) -> MLXArray {
        let mean3 = MLXArray(Self.pixelMean).reshaped([1, 3, 1, 1, 1])
        let std3 = MLXArray(Self.pixelStd).reshaped([1, 3, 1, 1, 1])
        return ((pixels.asType(.float32) + 1.0) * 0.5 - mean3) / std3
    }

    func encodeSingleShot(_ pixels: MLXArray, seed: UInt64 = 42) throws -> MLXArray {
        try sampleMoments(moments(normalizePixels(pixels)), seed: seed)
    }

    /// Single frame in, single latent frame out — the `T == 1` path, which is
    /// exactly what a keyframe or a reference image needs.
    ///
    /// The reference truncates to the last latent frame here because the causal
    /// front padding manufactures leading frames that carry no information.
    func encodeImage(_ pixels: MLXArray, seed: UInt64 = 42) throws -> MLXArray {
        precondition(pixels.dim(2) == 1,
                     "encodeImage wants one frame, got \(pixels.dim(2)); "
                     + "multi-frame clips need the temporal chunking that is not ported")
        let z = try encodeSingleShot(pixels, seed: seed)
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
    func tiledMoments(_ x: MLXArray) throws -> MLXArray {
        let h = x.dim(3), w = x.dim(4)
        let (yIdx, yLen, yOverlap) = VaeTiling.splitTiles(inputLen: h)
        let (xIdx, xLen, xOverlap) = VaeTiling.splitTiles(inputLen: w)

        var rows: [[MLXArray]] = []
        for (iPos, iLen) in zip(yIdx, yLen) {
            var row: [MLXArray] = []
            for (jPos, jLen) in zip(xIdx, xLen) {
                var t = VaeTiling.sliceDim(x, dim: 3, start: iPos, end: iPos + iLen)
                t = VaeTiling.sliceDim(t, dim: 4, start: jPos, end: jPos + jLen)
                row.append(try moments(t))
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
    func adaptiveMoments(_ normalized: MLXArray) throws -> MLXArray {
        try tiledMoments(normalized)
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
    func temporalMoments(_ normalized: MLXArray) throws -> MLXArray {
        let frames = normalized.dim(2)
        var x = normalized
        let pad = (config.clipLength - frames % config.clipLength) % config.clipLength
        if pad > 0 {
            let last = VaeTiling.sliceDim(x, dim: 2, start: frames - 1, end: frames)
            x = concatenated([x] + Array(repeating: last, count: pad), axis: 2)
        }
        let chunks = x.dim(2) / config.clipLength
        var z: [MLXArray] = []
        z.reserveCapacity(chunks)
        for i in 0 ..< chunks {
            let clip = VaeTiling.sliceDim(x, dim: 2,
                                          start: i * config.clipLength,
                                          end: (i + 1) * config.clipLength)
            z.append(try adaptiveMoments(clip))
        }
        var out = concatenated(z, axis: 2)
        if config.tokenDrop > 0 {
            out = VaeTiling.sliceDim(out, dim: 2, start: 0, end: out.dim(2) - config.tokenDrop)
        }
        return out
    }

    /// `[-1, 1]` pixels -> the normalized-pixel tensor the clips actually see.
    func normalized(_ pixels: MLXArray) -> MLXArray { normalizePixels(pixels) }

    /// Samples the released condition posterior with its fixed seed, rounds
    /// through float16, then applies the checkpoint's latent normalization.
    func sampleMoments(_ m: MLXArray, seed: UInt64 = 42) throws -> MLXArray {
        let mean = m[0..., 0 ..< config.latentChannels, 0..., 0..., 0...]
        let logVariance = clip(
            m[0..., config.latentChannels ..< (2 * config.latentChannels), 0..., 0..., 0...],
            min: -30.0,
            max: 20.0)
        let noise = MLXRandom.normal(mean.shape, key: MLXRandom.key(seed))
        let sampled = (mean + exp(0.5 * logVariance) * noise)
            .asType(.float16)
            .asType(.float32)
        return (sampled - MLXArray(latentsMean).reshaped([1, config.latentChannels, 1, 1, 1]))
             / MLXArray(latentsStd).reshaped([1, config.latentChannels, 1, 1, 1])
    }

    /// Pixels in `[-1, 1]` -> normalized latents, for any frame count.
    ///
    /// One frame keeps the last latent frame (the causal front pad manufactures
    /// leading frames that carry no information); more than one goes through
    /// ``temporalMoments(_:)``. Tiling is the reference's normal path, not a
    /// low-memory fallback, so both branches tile.
    ///
    /// Encoding is the whole of this module's job, so it is the module's call
    /// operator; the paths it picks between stay methods.
    func callAsFunction(_ pixels: MLXArray, seed: UInt64 = 42) throws -> MLXArray {
        let normalized = normalizePixels(pixels)
        if pixels.dim(2) == 1 {
            let z = try sampleMoments(adaptiveMoments(normalized), seed: seed)
            return z[0..., 0..., (z.dim(2) - 1) ..< z.dim(2), 0..., 0...]
        }
        return try sampleMoments(temporalMoments(normalized), seed: seed)
    }
}

/// The video VAE's decoder: a patch embedding, 36 transformer blocks and an
/// output projection.
///
/// A `Module` whose parts are declared under the checkpoint's names, filled by
/// ``H3Loader/loadVisualVAE(hub:configuration:)`` from the same read of the file.
/// The blocks are not declared: they are 9.669 GB of the file's 10.42 GB and
/// ``callAsFunction(_:)`` reads each one as the decode reaches it.
final class H3VisualVAEDecoder: Module {
    @ModuleInfo(key: "proj_in") var xEmbedder: H3Projection
    @ParameterInfo(key: "register_tokens") var registerTokens: MLXArray
    @ModuleInfo(key: "norm_out") var normOut: VaeLayerNorm
    @ModuleInfo(key: "proj_out") var projOut: H3Projection
    private var layers: [VaeTransformerBlock?]
    
    /// Built here rather than read: `decoder_rope_theta` and
    /// `decoder_rope_dim_ratio` state it — a quarter of each head's width is left
    /// unrotated.
    lazy var posEmbed = RotaryEmbeddingND(
        dim: Int(Float(config.decoderAttentionHeadDim) * config.decoderRopeDimRatio),
        theta: config.decoderRopeTheta)
    /// Where the checkpoint lives, and which file of it this is.
    private let hub: HubApi
    let configuration: H3Configuration
    /// Every dimension this VAE has, as `vae/config.json` states them. The
    /// widths were confirmed against the checkpoint's own shapes: `norm1` is
    /// `[2048]`, `to_q` is `[2048, 2048]`, `ff.net.2` is `[2048, 8192]`, and the
    /// whole file is **fp32** — which is what makes a 36-block stack 9.669 GB.
    var config: H3VideoVAEConfiguration { configuration.videoVAE }
    private var url: URL {
        get throws { try H3Loader.resolve(
            hub: hub, configuration: configuration, key: .videoVAEWeights) }
    }
    /// The block stack. `layers[i]` is block `i` while it is in memory and `nil`
    /// when it is not.
    ///
    /// Read once and never released: a decode walks this stack once per spatial
    /// tile — 28 tiles across 7 temporal chunks for a 5 s 768p render — and the
    /// whole walk is one lazy graph, so every block still has readers waiting
    /// when the next tile starts. Dropping one here would free nothing and make
    /// the next tile read it again.
    /// The declaration, with every parameter present but unread and no block
    /// built.
    init(hub: HubApi, configuration: H3Configuration) {
        self.hub = hub
        self.configuration = configuration
        let config = configuration.videoVAE
        self.layers = Array(repeating: nil, count: config.decoderLayers)
        self._xEmbedder.wrappedValue = H3Projection(
            inputDimensions: config.latentChannels, outputDimensions: config.decoderHidden)
        self._registerTokens.wrappedValue = MLXArray.zeros(
            [1, config.decoderRegisterTokens, config.decoderHidden])
        self._normOut.wrappedValue = VaeLayerNorm(
            dimensions: config.decoderHidden, eps: config.decoderNormEps)
        self._projOut.wrappedValue = H3Projection(
            inputDimensions: config.decoderHidden,
            outputDimensions: config.outChannels * config.patchSizeT
                * config.patchSize * config.patchSize)
    }

    func callAsFunction(_ x: MLXArray) throws -> MLXArray {
        let B = x.dim(0)
        let C = x.dim(1)
        let latentT = x.dim(2)
        let latentH = x.dim(3)
        let latentW = x.dim(4)

        let flattened = x.reshaped([B, C, -1])
        let transposed = flattened.transposed(0, 2, 1)

        var h = xEmbedder(transposed)

        let numPatches = h.dim(1)
        let numSuffix = 1 + config.decoderRegisterTokens

        let regExpanded = broadcast(registerTokens, to: [B, config.decoderRegisterTokens, registerTokens.dim(-1)])
        let zeroSuffix = MLXArray.zeros([B, 1, h.dim(-1)], dtype: h.dtype)

        h = concatenated([h, regExpanded, zeroSuffix], axis: 1)

        let imgIds = createTokenIds(latentT: latentT, latentH: latentH, latentW: latentW, dtype: h.dtype)
        let imgIdsExpanded = broadcast(imgIds, to: [B, imgIds.dim(1), imgIds.dim(2)])
        let suffixIds = MLXArray.zeros([B, numSuffix, 3], dtype: h.dtype)
        let imgIdsFull = concatenated([imgIdsExpanded, suffixIds], axis: 1)

        let rotaryPosEmb = posEmbed(imgIdsFull)

        for index in 0 ..< config.decoderLayers {
            if layers[index] == nil {
                layers[index] = try H3Loader.loadDecoderLayer(
                    index: index, url: try url, config: config)
            }
            h = layers[index]!(h, rotaryPosEmb: rotaryPosEmb)
        }

        var output = projOut(normOut(h))

        output = output[0..., 0 ..< numPatches, 0...]

        output = output.reshaped([
            B, latentT, latentH, latentW,
            config.outChannels, config.patchSizeT, config.patchSize, config.patchSize
        ])

        output = output.transposed(0, 4, 1, 5, 2, 6, 3, 7)

        output = output.reshaped([
            B, config.outChannels,
            latentT * config.patchSizeT,
            latentH * config.patchSize,
            latentW * config.patchSize
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
final class TemporalIsolatedGroupNorm: Module {
    @ParameterInfo var weight: MLXArray
    @ParameterInfo var bias: MLXArray
    let groups: Int
    /// 1e-6 here, not the 1e-5 that most frameworks default to.
    let eps: Float

    init(weight: MLXArray, bias: MLXArray, groups: Int = 32, eps: Float = 1e-6) {
        self.groups = groups
        self.eps = eps
        self._weight.wrappedValue = weight
        self._bias.wrappedValue = bias
    }

    /// The declaration's placeholder — the shapes `update` replaces.
    init(dimensions: Int, groups: Int = 32, eps: Float = 1e-6) {
        self.groups = groups
        self.eps = eps
        self._weight.wrappedValue = MLXArray.ones([dimensions])
        self._bias.wrappedValue = MLXArray.zeros([dimensions])
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
final class CausalConv3d: Module {
    /// Stored as the checkpoint has it, `[O, I, kT, kH, kW]` — PyTorch's order.
    /// MLX wants `[O, kT, kH, kW, I]`, so the transpose happens where the
    /// convolution is called. It is a view, and the encoder runs twice a render.
    @ParameterInfo var weight: MLXArray
    @ParameterInfo var bias: MLXArray?
    let stride: [Int]
    let padding: (t: Int, h: Int, w: Int)

    init(weight: MLXArray, bias: MLXArray?, stride: [Int] = [1, 1, 1],
         padding: (t: Int, h: Int, w: Int) = (0, 0, 0)) {
        self.stride = stride
        self.padding = padding
        self._weight.wrappedValue = weight
        self._bias.wrappedValue = bias
    }

    /// The declaration's placeholder — the shapes `update` replaces.
    init(weightShape: [Int], biasShape: [Int], stride: [Int] = [1, 1, 1],
         padding: (t: Int, h: Int, w: Int) = (0, 0, 0)) {
        self.stride = stride
        self.padding = padding
        self._weight.wrappedValue = MLXArray.zeros(weightShape)
        self._bias.wrappedValue = MLXArray.zeros(biasShape)
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
        var out = conv3d(p.transposed(0, 2, 3, 4, 1), weight.transposed(0, 2, 3, 4, 1),
                         stride: .init((stride[0], stride[1], stride[2])),
                         padding: .init((0, 0, 0)))
        if let bias { out = out + bias.reshaped([1, 1, 1, 1, bias.size]) }
        return out.transposed(0, 4, 1, 2, 3)
    }
}

final class VideoResnetBlock3D: Module {
    @ModuleInfo var norm1: TemporalIsolatedGroupNorm
    @ModuleInfo var norm2: TemporalIsolatedGroupNorm
    @ModuleInfo var conv1: CausalConv3d
    @ModuleInfo var conv2: CausalConv3d
    /// `conv_shortcut` — kernel 1, so no padding at all; it is a channel map.
    ///
    /// Present exactly where a level changes width, which the export confirms:
    /// `conv_shortcut` is there for down_blocks 1, 3 and 5 and nowhere else.
    @ModuleInfo(key: "conv_shortcut") var shortcut: CausalConv3d?

    init(inChannels: Int, outChannels: Int) {
        self._norm1.wrappedValue = TemporalIsolatedGroupNorm(dimensions: inChannels)
        self._norm2.wrappedValue = TemporalIsolatedGroupNorm(dimensions: outChannels)
        self._conv1.wrappedValue = CausalConv3d(
            weightShape: [outChannels, inChannels, 3, 3, 3], biasShape: [outChannels],
            padding: (1, 1, 1))
        self._conv2.wrappedValue = CausalConv3d(
            weightShape: [outChannels, outChannels, 3, 3, 3], biasShape: [outChannels],
            padding: (1, 1, 1))
        self._shortcut.wrappedValue = inChannels == outChannels ? nil
            : CausalConv3d(weightShape: [outChannels, inChannels, 1, 1, 1],
                           biasShape: [outChannels])
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = conv1(silu(norm1(x)))
        h = conv2(silu(norm2(h)))
        return h + (shortcut?(x) ?? x)
    }
}

final class VideoDownsample3D: Module {
    @ModuleInfo var conv: CausalConv3d
    let spaceStride: Int

    init(timeStride: Int, spaceStride: Int, channels: Int) {
        self.spaceStride = spaceStride
        self._conv.wrappedValue = CausalConv3d(
            weightShape: [channels, channels, 3, 3, 3], biasShape: [channels],
            stride: [timeStride, spaceStride, spaceStride], padding: (1, 0, 0))
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

final class H3VisualEncoderDownBlock: Module {
    @ModuleInfo(key: "resnets") var blocks: [VideoResnetBlock3D]
    /// Absent where a level does not downsample: down_blocks 4 and 5.
    @ModuleInfo(key: "downsamplers") var downsampler: VideoDownsample3D?

    init(inChannels: Int, midChannels: Int, timeStride: Int, spaceStride: Int,
         numResBlocks: Int) {
        self._blocks.wrappedValue = (0 ..< numResBlocks).map { i in
            VideoResnetBlock3D(inChannels: i == 0 ? inChannels : midChannels,
                               outChannels: midChannels)
        }
        self._downsampler.wrappedValue = spaceStride * timeStride > 1
            ? VideoDownsample3D(timeStride: timeStride, spaceStride: spaceStride,
                                channels: midChannels)
            : nil
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = x
        for b in blocks { h = b(h) }
        return downsampler?(h) ?? h
    }
}

/// A `Module` so a block can declare one and let `update(parameters:)` fill it
/// by path.
///
/// The weight is optional because this VAE norms its queries and keys *without*
/// one: the checkpoint carries `attn.norm_q` and `attn.norm_k` and no weight
/// under either, so a declaration that demanded one would be asking for a tensor
/// that is not there.
final class VaeRMSNorm: Module {
    @ParameterInfo var weight: MLXArray?
    let eps: Float

    init(weight: MLXArray? = nil, eps: Float = 1e-5) {
        self.eps = eps
        self._weight.wrappedValue = weight
    }

    /// The declaration's placeholder for a norm that does have a weight.
    init(dimensions: Int, eps: Float = 1e-5) {
        self.eps = eps
        self._weight.wrappedValue = MLXArray.ones([dimensions])
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

/// LayerNorm over the last axis, computed in fp32 and cast back.
///
/// A `Module` rather than a struct so a container can declare one with
/// `@ModuleInfo` and let `update(parameters:)` fill it by path.
///
/// The tensor-taking initializer stays for the callers that already hold the
/// weights. `dimensions` allocates the shapes an `update` will replace, which is
/// what a container needs before it has read anything: a parameter is filled by
/// being looked up in the module's own structure, so it has to exist first, and
/// a `@ParameterInfo` left nil is a crash in that lookup rather than a
/// placeholder.
final class VaeLayerNorm: Module {
    @ParameterInfo var weight: MLXArray
    @ParameterInfo var bias: MLXArray
    let eps: Float

    init(weight: MLXArray, bias: MLXArray, eps: Float = 1e-5) {
        self.eps = eps
        self._weight.wrappedValue = weight
        self._bias.wrappedValue = bias
    }

    init(dimensions: Int, eps: Float = 1e-5) {
        self.eps = eps
        self._weight.wrappedValue = MLXArray.ones([dimensions])
        self._bias.wrappedValue = MLXArray.zeros([dimensions])
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

final class VaeAttention: Module {
    /// Both carry no weight — see ``VaeRMSNorm``.
    @ModuleInfo(key: "norm_q") var normQ: VaeRMSNorm
    @ModuleInfo(key: "norm_k") var normK: VaeRMSNorm
    @ModuleInfo(key: "to_q") var toQ: H3Projection
    @ModuleInfo(key: "to_k") var toK: H3Projection
    @ModuleInfo(key: "to_v") var toV: H3Projection
    @ModuleInfo(key: "to_out") var toOut: H3Projection
    let heads: Int
    let dimHead: Int

    init(hidden: Int, heads: Int, dimHead: Int, eps: Float) {
        self.heads = heads
        self.dimHead = dimHead
        self._normQ.wrappedValue = VaeRMSNorm(eps: eps)
        self._normK.wrappedValue = VaeRMSNorm(eps: eps)
        let inner = heads * dimHead
        self._toQ.wrappedValue = H3Projection(
            inputDimensions: hidden, outputDimensions: inner)
        self._toK.wrappedValue = H3Projection(
            inputDimensions: hidden, outputDimensions: inner)
        self._toV.wrappedValue = H3Projection(
            inputDimensions: hidden, outputDimensions: inner)
        self._toOut.wrappedValue = H3Projection(
            inputDimensions: inner, outputDimensions: hidden)
    }

    func callAsFunction(_ x: MLXArray, rotaryPosEmb: MLXArray?) -> MLXArray {
        let B = x.dim(0)
        let S = x.dim(1)

        var q = normQ(toQ(x).reshaped([B, S, heads, dimHead]))
        var k = normK(toK(x).reshaped([B, S, heads, dimHead]))
        let value = toV(x).reshaped([B, S, heads, dimHead])

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
        return toOut(merged)
    }
}

/// `fc2(silu(gate) * up)` — `w1` emits twice the feed-forward width and the first
/// half is the gate.
final class VaeFeedForward: Module {
    @ModuleInfo var w1: H3Projection
    @ModuleInfo var w2: H3Projection

    init(hidden: Int, inner: Int) {
        self._w1.wrappedValue = H3Projection(
            inputDimensions: hidden, outputDimensions: 2 * inner)
        self._w2.wrappedValue = H3Projection(
            inputDimensions: inner, outputDimensions: hidden)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let h = w1(x)
        let innerDim = h.dim(-1) / 2
        let gate = h[0..., 0..., 0 ..< innerDim]
        let up = h[0..., 0..., innerDim...]
        return w2(silu(gate) * up)
    }
}

/// One of the decoder's 36 blocks: pre-norm attention, pre-norm feed-forward, each
/// residual scaled by a learned scalar.
///
/// A `Module` whose parts are declared under the checkpoint's names, so
/// ``H3Loader/loadDecoderLayer(index:url:)`` builds one by filling this from the
/// tensors whose names start `decoder.transformer_blocks.<index>.`. A mis-wiring
/// would not fail to load, it would produce a plausible-looking wrong frame.
final class VaeTransformerBlock: Module {
    @ModuleInfo var norm1: VaeRMSNorm
    @ModuleInfo var norm2: VaeRMSNorm
    @ModuleInfo var attn: VaeAttention
    @ModuleInfo var ff: VaeFeedForward
    @ParameterInfo var scale1: MLXArray
    @ParameterInfo var scale2: MLXArray

    /// The declaration, with every parameter present but unread.
    init(config: H3VideoVAEConfiguration) {
        let hidden = config.decoderHidden
        self._norm1.wrappedValue = VaeRMSNorm(
            dimensions: hidden, eps: config.decoderNormEps)
        self._norm2.wrappedValue = VaeRMSNorm(
            dimensions: hidden, eps: config.decoderNormEps)
        self._attn.wrappedValue = VaeAttention(
            hidden: hidden, heads: config.decoderAttentionHeads,
            dimHead: config.decoderAttentionHeadDim, eps: config.decoderNormEps)
        self._ff.wrappedValue = VaeFeedForward(
            hidden: hidden, inner: config.decoderFFNInner)
        // Per-residual-channel scales, not scalars: the export stores both as
        // `[2048]`, one weight per channel of the stream they scale.
        self._scale1.wrappedValue = MLXArray.ones([hidden])
        self._scale2.wrappedValue = MLXArray.ones([hidden])
    }

    func callAsFunction(_ x: MLXArray, rotaryPosEmb: MLXArray?) -> MLXArray {
        let h1 = norm1(x)
        let x1 = x + attn(h1, rotaryPosEmb: rotaryPosEmb) * scale1
        let h2 = norm2(x1)
        return x1 + ff(h2) * scale2
    }
}
