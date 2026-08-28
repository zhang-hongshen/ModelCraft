// SPDX-License-Identifier: Apache-2.0

import Foundation
import Hub
import MLX
import MLXFast
import MLXNN

enum H3VisionPreprocess {
    static let mean: Float = 0.5
    static let std: Float = 0.5

    /// Target patch grid for an image, given the reference's rounding rules.
    ///
    /// The min/max pixel clamps exist in the reference and are reproduced here,
    /// but note the H3 path never approaches either: 3136 px is a 56x56 image
    /// and 12.8 Mpx is larger than anything a prompt carries.
    static func grid(width: Int, height: Int,
                            config: H3VisionEncoderConfiguration = H3VisionEncoderConfiguration(),
                            minPixels: Int = 3136, maxPixels: Int = 12_845_056)
        -> (width: Int, height: Int, grid: H3VisionGrid) {
        let factor = config.patchSize * config.spatialMergeSize
        var hBar = Int((Double(height) / Double(factor)).rounded()) * factor
        var wBar = Int((Double(width) / Double(factor)).rounded()) * factor

        if hBar * wBar > maxPixels {
            let beta = (Double(height) * Double(width) / Double(maxPixels)).squareRoot()
            hBar = max(factor, Int((Double(height) / beta / Double(factor)).rounded(.down)) * factor)
            wBar = max(factor, Int((Double(width) / beta / Double(factor)).rounded(.down)) * factor)
        } else if hBar * wBar < minPixels {
            let beta = (Double(minPixels) / (Double(height) * Double(width))).squareRoot()
            hBar = Int((Double(height) * beta / Double(factor)).rounded(.up)) * factor
            wBar = Int((Double(width) * beta / Double(factor)).rounded(.up)) * factor
        }
        return (wBar, hBar, H3VisionGrid(h: hBar / config.patchSize, w: wBar / config.patchSize))
    }

    /// Already-resized image `[1, H, W, 3]` in [0, 1] -> `[tokens, 1536]`.
    ///
    /// Resizing is the caller's job because it belongs to whatever decoded the
    /// file; this is the part that has to match the reference bit for bit.
    static func patches(image: MLXArray, grid: H3VisionGrid,
                               config: H3VisionEncoderConfiguration = H3VisionEncoderConfiguration()) throws -> MLXArray {
        let p = config.patchSize
        let tp = config.temporalPatchSize
        guard image.dim(1) == grid.h * p && image.dim(2) == grid.w * p else {
            throw H3EvaluatorError.mediaOffCanvas(
                path: "presented image", size: "\(image.dim(2))x\(image.dim(1))",
                remedy: "this grid wants \(grid.w * p)x\(grid.h * p). Resizing belongs to "
                      + "whatever decoded the file; this step has to match the reference bit "
                      + "for bit and so will not resize for you.")
        }

        let norm = (image.asType(.float32).transposed(0, 3, 1, 2) - mean) / std  // [1,3,H,W]
        // The single frame is repeated across the temporal patch: the tower
        // always consumes 2 frames, and a still image is both of them.
        let rep = tiled(norm, repetitions: [tp, 1, 1, 1])                        // [2,3,H,W]
        return pack(rep, grid: grid, config: config)
    }

    /// Already-resized video `[T, H, W, 3]` in `[0, 1]` -> Qwen video patches.
    ///
    /// Qwen3-VL merges frames in temporal groups of two. The last frame is
    /// repeated when the sampled frame count is odd, exactly as the official
    /// Ref2VA processor does before it emits one timestamped vision block per
    /// temporal group.
    static func patches(
        video: MLXArray,
        grid: H3VisionGrid,
        config: H3VisionEncoderConfiguration = H3VisionEncoderConfiguration()
    ) throws -> MLXArray {
        let patch = config.patchSize
        let temporalPatch = config.temporalPatchSize
        guard video.ndim == 4,
              video.dim(1) == grid.h * patch,
              video.dim(2) == grid.w * patch
        else {
            throw H3EvaluatorError.mediaOffCanvas(
                path: "presented reference video",
                size: "\(video.dim(2))x\(video.dim(1))",
                remedy: "resize every sampled reference frame to the Qwen3-VL grid before packing.")
        }

        let expectedFrames = grid.t * temporalPatch
        guard video.dim(0) > 0, video.dim(0) <= expectedFrames else {
            throw H3EvaluatorError.invalidRequest(
                rule: "invalid reference video sample count",
                detail: "\(video.dim(0)) frame(s) for \(grid.t) temporal block(s)",
                remedy: "sample the video at 2 fps and group frames in pairs.")
        }

        var frames = video
        if frames.dim(0) < expectedFrames {
            let last = frames[(frames.dim(0) - 1) ..< frames.dim(0)]
            frames = concatenated(
                [frames, tiled(last, repetitions: [expectedFrames - frames.dim(0), 1, 1, 1])],
                axis: 0)
        }
        let normalized = (frames.asType(.float32).transposed(0, 3, 1, 2) - mean) / std
        return pack(normalized, grid: grid, config: config)
    }

    /// The 9-way permutation used by the still-image path.
    static func pack(_ norm: MLXArray, grid: H3VisionGrid,
                     config: H3VisionEncoderConfiguration) -> MLXArray {
        let p = config.patchSize, m = config.spatialMergeSize
        let tp = config.temporalPatchSize, ch = config.inChannels
        return norm.reshaped([grid.t, tp, ch,
                              grid.h / m, m, p,
                              grid.w / m, m, p])
                   .transposed(0, 3, 6, 4, 7, 2, 1, 5, 8)
                   .reshaped([grid.tokens, ch * tp * p * p])
    }
}

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Kammerich


/// The Qwen3-VL vision tower, as shipped inside the H3 conditioning weights.
///
/// 351 of the file's 902 tensors, under `visual.*`: a patch embedding, a 48x48
/// learned position grid, 27 blocks at 1152-dim, a merger that projects into the
/// language model's 5120-dim space, and — the Qwen3-VL-specific part — three
/// **deepstack** mergers that tap layers 8, 16 and 24 and inject those features
/// back into the language stack at the image's token positions.
///
/// It is reachable only through **image prompts**. It has nothing to do with
/// I2V keyframes, which go through the Visual VAE; confusing the two is easy
/// because both take an image and both feed the DiT.
struct H3VisionEncoderConfiguration: Sendable, Equatable {
    var hiddenSize = 1152
    var intermediateSize = 4304
    var depth = 27
    var numHeads = 16
    var patchSize = 16
    var temporalPatchSize = 2
    var inChannels = 3
    var spatialMergeSize = 2
    /// 2304 = 48x48. The grid is bilinearly resampled to each image's shape.
    var numPositionEmbeddings = 2304
    /// H3's language hidden size — what the merger projects into.
    var outHiddenSize = 5120
    /// Layers whose output is tapped for deepstack injection.
    var deepstackIndexes = [8, 16, 24]
    init() {}

    var headDim: Int { hiddenSize / numHeads }
    /// RoPE is applied over half the head dim, split again between row and col.
    var rotaryDim: Int { headDim / 2 }
    var gridPerSide: Int { Int(Double(numPositionEmbeddings).squareRoot()) }
    var mergeUnit: Int { spatialMergeSize * spatialMergeSize }
    var mergeDim: Int { hiddenSize * mergeUnit }
}

/// `[T, H, W]` patch counts for one image or sampled reference video.
struct H3VisionGrid: Sendable, Equatable {
    let t: Int, h: Int, w: Int
    init(t: Int = 1, h: Int, w: Int) { self.t = t; self.h = h; self.w = w }
    var tokens: Int { t * h * w }
}

final class H3VisionEncoder {
    let config: H3VisionEncoderConfiguration

    struct Block {
        let norm1: VaeLayerNorm, norm2: VaeLayerNorm
        let qkv: MLXArray, qkvBias: MLXArray
        let proj: MLXArray, projBias: MLXArray
        let fc1: MLXArray, fc1Bias: MLXArray
        let fc2: MLXArray, fc2Bias: MLXArray
    }

    /// The two mergers differ in **where the norm sits**, and the model export
    /// says so: `merger.norm.weight` is `[1152]`, the deepstack ones `[4608]`.
    /// The main merger normalizes each patch *before* the spatial merge;
    /// deepstack normalizes the merged 4x vector *after*. Same weight names,
    /// different semantics.
    struct Merger {
        let norm: VaeLayerNorm
        let fc1: MLXArray, fc1Bias: MLXArray
        let fc2: MLXArray, fc2Bias: MLXArray
        let postShuffleNorm: Bool
    }

    let patchProj: MLXArray, patchProjBias: MLXArray
    let posEmbed: MLXArray
    let blocks: [Block]
    let merger: Merger
    let deepstackMergers: [Merger]

    enum Error: Swift.Error, CustomStringConvertible {
        case missing(String)
        var description: String {
            switch self { case .missing(let n): "vision tower has no tensor named \(n)" }
        }
    }

    init(weights: [String: MLXArray], config: H3VisionEncoderConfiguration = H3VisionEncoderConfiguration(),
                prefix: String? = nil) throws {
        self.config = config
        let resolvedPrefix: String
        if let prefix {
            resolvedPrefix = prefix
        } else {
            if weights.keys.contains(where: { $0.hasPrefix("model.visual.") }) {
                resolvedPrefix = "model.visual."
            } else {
                resolvedPrefix = "visual."
            }
        }
        func w(_ n: String) throws -> MLXArray {
            guard let a = weights[resolvedPrefix + n] else { throw Error.missing(resolvedPrefix + n) }
            return a
        }

        // The patch embedding is a Conv3d whose stride equals its kernel, applied
        // to inputs that are already one patch each — so it is a matmul wearing
        // a convolution's shape. [1152, 3, 2, 16, 16] flattens to [1152, 1536],
        // which is exactly the width of a `flatten_patches` row.
        let pw = try w("patch_embed.proj.weight")
        self.patchProj = pw.reshaped([config.hiddenSize, -1])
        self.patchProjBias = try w("patch_embed.proj.bias")
        self.posEmbed = try w("pos_embed.weight")

        self.blocks = try (0 ..< config.depth).map { i in
            let b = "blocks.\(i)."
            return Block(
                norm1: VaeLayerNorm(weight: try w(b + "norm1.weight"),
                                    bias: try w(b + "norm1.bias"), eps: 1e-6),
                norm2: VaeLayerNorm(weight: try w(b + "norm2.weight"),
                                    bias: try w(b + "norm2.bias"), eps: 1e-6),
                qkv: try w(b + "attn.qkv.weight"), qkvBias: try w(b + "attn.qkv.bias"),
                proj: try w(b + "attn.proj.weight"), projBias: try w(b + "attn.proj.bias"),
                fc1: try w(b + "mlp.linear_fc1.weight"), fc1Bias: try w(b + "mlp.linear_fc1.bias"),
                fc2: try w(b + "mlp.linear_fc2.weight"), fc2Bias: try w(b + "mlp.linear_fc2.bias"))
        }

        func merger(_ p: String, postShuffle: Bool) throws -> Merger {
            Merger(norm: VaeLayerNorm(weight: try w(p + "norm.weight"),
                                      bias: try w(p + "norm.bias"), eps: 1e-6),
                   fc1: try w(p + "linear_fc1.weight"), fc1Bias: try w(p + "linear_fc1.bias"),
                   fc2: try w(p + "linear_fc2.weight"), fc2Bias: try w(p + "linear_fc2.bias"),
                   postShuffleNorm: postShuffle)
        }
        self.merger = try merger("merger.", postShuffle: false)
        self.deepstackMergers = try (0 ..< config.deepstackIndexes.count).map {
            try merger("deepstack_merger_list.\($0).", postShuffle: true)
        }
    }

    convenience init(
        hub: HubApi,
        configuration: H3Configuration,
        config: H3VisionEncoderConfiguration = H3VisionEncoderConfiguration()
    ) throws {
        try self.init(
            weights: H3Loader.loadWeights(
                hub: hub,
                configuration: configuration,
                key: "textEncoderWeights"),
            config: config)
    }

    // MARK: - position encodings

    /// Bilinear resample of the learned 48x48 grid onto this image's patch grid,
    /// then reordered into merge-block order.
    ///
    /// The reorder is the subtle half. Tokens are not in raster order: they are
    /// grouped so that each consecutive run of `mergeUnit` tokens is one 2x2
    /// block, because that is what the merger reshapes over. Getting the
    /// interpolation right and the permutation wrong leaves every value present
    /// and every one in the wrong row.
    func positionEmbeddings(_ grid: H3VisionGrid) -> MLXArray {
        let side = config.gridPerSide
        let m = config.spatialMergeSize

        func axis(_ n: Int) -> (floor: [Int32], ceil: [Int32], frac: [Float]) {
            // linspace(0, side-1, n) — endpoint inclusive, and n == 1 pins to 0.
            let step = n > 1 ? Double(side - 1) / Double(n - 1) : 0
            var f = [Int32](), c = [Int32](), d = [Float]()
            for i in 0 ..< n {
                let v = Double(i) * step
                // `.int()` in the reference truncates toward zero; v >= 0 here.
                let lo = Int32(v)
                f.append(lo)
                c.append(min(lo + 1, Int32(side - 1)))
                d.append(Float(v - Double(lo)))
            }
            return (f, c, d)
        }
        let (hf, hc, dh) = axis(grid.h)
        let (wf, wc, dw) = axis(grid.w)

        // Four corners of the bilinear tap, weighted and summed.
        let hFloor = MLXArray(hf).reshaped([grid.h, 1])
        let hCeil = MLXArray(hc).reshaped([grid.h, 1])
        let wFloor = MLXArray(wf).reshaped([1, grid.w])
        let wCeil = MLXArray(wc).reshaped([1, grid.w])
        let dhA = MLXArray(dh).reshaped([grid.h, 1])
        let dwA = MLXArray(dw).reshaped([1, grid.w])

        let corners = [
            (hFloor * Int32(side) + wFloor, (1.0 - dhA) * (1.0 - dwA)),
            (hFloor * Int32(side) + wCeil, (1.0 - dhA) * dwA),
            (hCeil * Int32(side) + wFloor, dhA * (1.0 - dwA)),
            (hCeil * Int32(side) + wCeil, dhA * dwA),
        ]
        var acc: MLXArray?
        for (idx, weight) in corners {
            let e = posEmbed[idx.flattened()] * weight.flattened().reshaped([-1, 1])
            acc = acc == nil ? e : acc! + e
        }
        var pos = acc!                                          // [h*w, hidden] raster

        // raster -> merge-block order
        pos = pos.reshaped([grid.h / m, m, grid.w / m, m, config.hiddenSize])
                 .transposed(0, 2, 1, 3, 4)
                 .reshaped([grid.h * grid.w, config.hiddenSize])
        if grid.t > 1 {
            pos = tiled(pos, repetitions: [grid.t, 1])
        }
        return pos
    }

    /// 2-D RoPE frequencies: `[tokens, rotaryDim]`, row half then column half.
    func ropeFrequencies(_ grid: H3VisionGrid) -> MLXArray {
        let m = config.spatialMergeSize
        let half = config.rotaryDim / 2                          // 18 for 1152/16
        let theta: Float = 10_000

        let exponent = MLXArray(stride(from: 0, to: config.rotaryDim, by: 2).map { Float($0) })
            / Float(config.rotaryDim)
        let invFreq = 1.0 / pow(MLXArray(theta), exponent)       // [half]
        let maxHW = max(grid.h, grid.w)
        let table = MLXArray(0 ..< maxHW).asType(.float32).reshaped([maxHW, 1])
            * invFreq.reshaped([1, half])                        // [maxHW, half]

        // Row/col index per token, in the same merge-block order as the position
        // embeddings — built by the same reshape rather than a second formula,
        // so the two cannot drift apart.
        let rows = broadcast(MLXArray(0 ..< grid.h).reshaped([grid.h, 1]), to: [grid.h, grid.w])
        let cols = broadcast(MLXArray(0 ..< grid.w).reshaped([1, grid.w]), to: [grid.h, grid.w])
        func blockOrder(_ a: MLXArray) -> MLXArray {
            a.reshaped([grid.h / m, m, grid.w / m, m])
             .transposed(0, 2, 1, 3)
             .reshaped([grid.h * grid.w])
        }
        var r = blockOrder(rows), c = blockOrder(cols)
        if grid.t > 1 {
            r = tiled(r, repetitions: [grid.t])
            c = tiled(c, repetitions: [grid.t])
        }
        return concatenated([table[r], table[c]], axis: -1)      // [tokens, rotaryDim]
    }

    /// Split-half rotation over the full head dim.
    ///
    /// The reference builds `emb = cat(rot, rot)` and then splits cos/sin back
    /// in half, so both halves see the same angle — which is plain
    /// rotate-half RoPE written the long way round.
    static func applyRoPE(_ x: MLXArray, cos c: MLXArray, sin s: MLXArray) -> MLXArray {
        let half = x.dim(-1) / 2
        let lo = x[.ellipsis, 0 ..< half]
        let hi = x[.ellipsis, half ..< (2 * half)]
        return concatenated([lo * c - hi * s, hi * c + lo * s], axis: -1)
    }

    // MARK: - forward

    struct Output {
        /// `[mergedTokens, outHiddenSize]` — what splices into the prompt.
        let merged: MLXArray
        /// One per deepstack index, same shape as `merged`.
        let deepstack: [MLXArray]
    }

    /// - Parameter patches: `[tokens, inChannels * temporalPatch * patch * patch]`,
    ///   the `flatten_patches` layout — already resized, normalized and
    ///   permuted. See ``H3VisionPreprocess``.
    func callAsFunction(patches: MLXArray, grid: H3VisionGrid) -> Output {
        precondition(patches.dim(0) == grid.tokens,
                     "grid \(grid) wants \(grid.tokens) patches, got \(patches.dim(0))")
        let s = grid.tokens
        var x = matmul(patches.asType(.float32), patchProj.T) + patchProjBias
        x = x + positionEmbeddings(grid)

        let freqs = ropeFrequencies(grid)                        // [S, rotaryDim]
        let c = cos(freqs).expandedDimensions(axis: 1)           // [S, 1, rotaryDim]
        let sn = sin(freqs).expandedDimensions(axis: 1)

        var intermediate: [Int: MLXArray] = [:]
        // Attention runs per image. H3 sends one image at a time, so there is a
        // single segment and no mask is needed — the reference splits on
        // `cu_seqlens` for exactly this reason and would need a block-diagonal
        // mask if it did not.
        let scale = 1.0 / Float(config.headDim).squareRoot()
        for (i, b) in blocks.enumerated() {
            let h = b.norm1(x)
            let qkv = matmul(h, b.qkv.T) + b.qkvBias
            let parts = qkv.reshaped([s, 3, config.numHeads, config.headDim])
                           .transposed(1, 0, 2, 3)
            let q = Self.applyRoPE(parts[0], cos: c, sin: sn)
            let k = Self.applyRoPE(parts[1], cos: c, sin: sn)
            let v = parts[2]

            let o = MLXFast.scaledDotProductAttention(
                queries: q.transposed(1, 0, 2).expandedDimensions(axis: 0),
                keys: k.transposed(1, 0, 2).expandedDimensions(axis: 0),
                values: v.transposed(1, 0, 2).expandedDimensions(axis: 0),
                scale: scale, mask: nil)
            let attn = o.squeezed(axis: 0).transposed(1, 0, 2).reshaped([s, config.hiddenSize])
            x = x + matmul(attn, b.proj.T) + b.projBias

            let y = b.norm2(x)
            // GELU is the tanh approximation throughout this tower.
            let up = geluApproximate(matmul(y, b.fc1.T) + b.fc1Bias)
            x = x + matmul(up, b.fc2.T) + b.fc2Bias
            intermediate[i] = x
            if i % 10 == 0 { eval(x) }
        }

        var deepstack: [MLXArray] = []
        for (slot, layer) in config.deepstackIndexes.enumerated() {
            guard let feat = intermediate[layer] else { continue }
            deepstack.append(apply(deepstackMergers[slot], feat))
        }
        return Output(merged: apply(merger, x), deepstack: deepstack)
    }

    /// `fc2(gelu(fc1(norm(x))))` with the merge reshape either side of the norm.
    private func apply(_ m: Merger, _ x: MLXArray) -> MLXArray {
        let merged = m.postShuffleNorm
            ? m.norm(x.reshaped([-1, config.mergeDim]))          // norm after merge
            : m.norm(x).reshaped([-1, config.mergeDim])          // norm before merge
        let h = geluApproximate(matmul(merged, m.fc1.T) + m.fc1Bias)
        return matmul(h, m.fc2.T) + m.fc2Bias
    }
}

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Kammerich


/// Qwen3-VL-32B, the conditioning encoder — language path only.
///
/// H3 loads the Qwen3-VL-32B language checkpoint and exposes the hidden state
/// after layer 50. The full SafeTensors inventory is read and its layer count is
/// retained; only the first 50 layers are evaluated because that is the state
/// consumed by H3 Base. There is no final norm or lm_head in the conditioning
/// path, and the decoder's causal attention mask is preserved.
///
/// The vision tower ships in the same file (27 blocks, 1152-dim) and is loaded
/// by ``H3VisionEncoder`` when a FL2VA keyframe is present. This type handles
/// only the language path.
struct H3TextEncoderConfiguration: Sendable, Equatable {
    var hiddenSize = 5120
    var numLayers = 50
    var numHeads = 64
    /// Grouped-query attention: 64 query heads share 8 key/value heads.
    var numKVHeads = 8
    var headDim = 128
    var intermediateSize = 25600
    var vocabSize = 151_936
    var rmsNormEps: Float = 1e-6
    /// 5e6, not the 1e6 of plain Qwen3 — the VL variant widens it.
    var ropeTheta: Float = 5_000_000.0
    /// Interleaved-mRoPE band widths for t, h, w. They sum to `headDim / 2`.
    var ropeDims = [24, 20, 20]
    init() {}

    var innerDim: Int { numHeads * headDim }
    var kvDim: Int { numKVHeads * headDim }
}

final class H3TextEncoder {
    let config: H3TextEncoderConfiguration
    let url: URL
    /// Number of language layers present in the downloaded checkpoint.
    let checkpointLayerCount: Int

    struct Layer {
        let inputNorm: H3RMSNorm
        let postAttnNorm: H3RMSNorm
        let q: MLXArray, k: MLXArray, v: MLXArray, o: MLXArray
        let qNorm: H3RMSNorm, kNorm: H3RMSNorm
        let gate: MLXArray, up: MLXArray, down: MLXArray
    }

    let embedTokens: MLXArray
    let layers: [Layer]

    enum Error: Swift.Error, CustomStringConvertible {
        case missing(String)
        case unexpected(String)
        var description: String {
            switch self {
            case .missing(let n): "text encoder weights have no tensor named \(n)"
            case .unexpected(let m): m
            }
        }
    }

    /// The language stack can be exported with either of these prefixes. The
    /// payload is the same; only the prefix moves.
    ///
    ///     model.layers.N.*
    ///     model.language_model.layers.N.*
    ///
    /// Detected from the keys rather than assumed, and reported, because a
    /// silent wrong guess here fails as "missing tensor" fifty layers deep.
    static func languagePrefix(_ names: some Collection<String>) throws -> String {
        let s = Set(names)
        if s.contains("model.layers.0.self_attn.q_proj.weight") { return "model." }
        if s.contains("model.language_model.layers.0.self_attn.q_proj.weight") {
            return "model.language_model."
        }
        throw Error.unexpected("cannot find the language stack under either "
                              + "`model.layers.` or `model.language_model.layers.` — "
                              + "is this a Qwen3-VL conditioning export?")
    }

    init(url: URL, config: H3TextEncoderConfiguration = H3TextEncoderConfiguration()) throws {
        self.url = url
        self.config = config
        let all = try H3Loader.loadWeights(from: url)
        let p = try Self.languagePrefix(all.keys)

        func w(_ n: String) throws -> MLXArray {
            guard let a = all[n] else { throw Error.missing(n) }
            return a
        }
        // Layer count comes from the file, and disagreeing with the reference
        // is a loud failure: a 64-layer export would silently produce the
        // wrong hidden state.
        let present = all.keys.compactMap { key -> Int? in
            guard key.hasPrefix(p + "layers.") else { return nil }
            let rest = key.dropFirst((p + "layers.").count)
            guard let dot = rest.firstIndex(of: ".") else { return nil }
            return Int(rest[rest.startIndex ..< dot])
        }
        let found = (present.max() ?? -1) + 1
        guard found >= config.numLayers else {
            throw Error.unexpected("weights have \(found) language layers, but H3 needs "
                                  + "at least \(config.numLayers) to read the layer-50 state")
        }

        self.checkpointLayerCount = found
        self.embedTokens = try w(p + "embed_tokens.weight")
        var built: [Layer] = []
        built.reserveCapacity(config.numLayers)
        for i in 0 ..< config.numLayers {
            let b = p + "layers.\(i)."
            built.append(Layer(
                inputNorm: H3RMSNorm(weight: try w(b + "input_layernorm.weight"),
                                     eps: config.rmsNormEps),
                postAttnNorm: H3RMSNorm(weight: try w(b + "post_attention_layernorm.weight"),
                                        eps: config.rmsNormEps),
                q: try w(b + "self_attn.q_proj.weight"),
                k: try w(b + "self_attn.k_proj.weight"),
                v: try w(b + "self_attn.v_proj.weight"),
                o: try w(b + "self_attn.o_proj.weight"),
                qNorm: H3RMSNorm(weight: try w(b + "self_attn.q_norm.weight"),
                                 eps: config.rmsNormEps),
                kNorm: H3RMSNorm(weight: try w(b + "self_attn.k_norm.weight"),
                                 eps: config.rmsNormEps),
                gate: try w(b + "mlp.gate_proj.weight"),
                up: try w(b + "mlp.up_proj.weight"),
                down: try w(b + "mlp.down_proj.weight")))
        }
        self.layers = built
    }

    convenience init(
        hub: HubApi,
        configuration: H3Configuration,
        config: H3TextEncoderConfiguration = H3TextEncoderConfiguration()
    ) throws {
        try self.init(
            url: H3Loader.resolve(
                hub: hub,
                configuration: configuration,
                key: "textEncoderWeights"),
            config: config)
    }

    /// `[S, headDim]` cos and sin for positions `0 ..< count`.
    ///
    /// Plain RoPE. A pure-text prompt gets `arange(S)` as a single row, which is
    /// what this computes; image prompts take ``mrope(positionIds:dtype:)``
    /// instead.
    func rope(count: Int, dtype: DType) -> (cos: MLXArray, sin: MLXArray) {
        let half = config.headDim / 2
        let exponent = MLXArray(0 ..< half).asType(.float32) * (2.0 / Float(config.headDim))
        let invFreq = 1.0 / pow(MLXArray(config.ropeTheta), exponent)
        let pos = MLXArray(0 ..< count).asType(.float32).reshaped([count, 1])
        let freqs = pos * invFreq.reshaped([1, half])              // [S, half]
        let emb = concatenated([freqs, freqs], axis: -1)           // [S, headDim]
        return (cos(emb).asType(dtype), sin(emb).asType(dtype))
    }

    /// **Interleaved** mRoPE, for three rows of position ids.
    ///
    /// Qwen3-VL does not give t, h and w contiguous slices of the frequency
    /// band. T is the default everywhere, and h and w then *replace every third
    /// dimension*: h at `1, 4, 7, ...` and w at `2, 5, 8, ...`, both stopping at
    /// `ropeDims[axis] * 3`. With `ropeDims = [24, 20, 20]` that leaves h and w
    /// 20 dimensions each and t the remaining 24 — the same split the
    /// non-interleaved layout would have used, scattered rather than blocked.
    ///
    /// The contiguous `mrope_section` branch in the same reference function is
    /// the Qwen2-VL layout. Both are present; only this one applies here.
    ///
    /// - Parameter positionIds: `[3, S]`, float-valued t/h/w rows.
    func mrope(positionIds: MLXArray, dtype: DType) -> (cos: MLXArray, sin: MLXArray) {
        let half = config.headDim / 2
        let s = positionIds.dim(1)
        let exponent = MLXArray(0 ..< half).asType(.float32) * (2.0 / Float(config.headDim))
        let invFreq = 1.0 / pow(MLXArray(config.ropeTheta), exponent)   // [half]

        // [3, S, half]
        let freqs = positionIds.asType(.float32).reshaped([3, s, 1]) * invFreq.reshaped([1, 1, half])

        // Start from t, then overwrite the h and w positions.
        var lane = [Int32](repeating: 0, count: half)
        for (axis, offset) in [(1, 1), (2, 2)] {
            var i = offset
            while i < config.ropeDims[axis] * 3 && i < half {
                lane[i] = Int32(axis)
                i += 3
            }
        }
        let laneIdx = broadcast(MLXArray(lane).reshaped([1, 1, half]), to: [1, s, half])
        let inter = takeAlong(freqs, laneIdx, axis: 0).squeezed(axis: 0)  // [S, half]
        let emb = concatenated([inter, inter], axis: -1)                // [S, headDim]
        return (cos(emb).asType(dtype), sin(emb).asType(dtype))
    }

    /// Split-half rotation on `[1, heads, S, headDim]`.
    static func applyRoPE(_ x: MLXArray, cos c: MLXArray, sin s: MLXArray) -> MLXArray {
        let half = x.dim(-1) / 2
        let lo = x[.ellipsis, 0 ..< half]
        let hi = x[.ellipsis, half ..< (2 * half)]
        let cLo = c[0..., 0 ..< half], sLo = s[0..., 0 ..< half]
        return concatenated([lo * cLo - hi * sLo, hi * cLo + lo * sLo], axis: -1)
    }

    /// Additive causal mask. The reference uses `finfo(dtype).min / 4` rather
    /// than -inf; both underflow to zero through softmax, and staying finite
    /// avoids NaN if a row were ever fully masked.
    static func causalMask(_ n: Int, dtype: DType) -> MLXArray {
        let idx = MLXArray(0 ..< n)
        let rows = idx.reshaped([n, 1]), cols = idx.reshaped([1, n])
        let blocked = cols .> rows
        return MLX.where(blocked, MLXArray(-1e30 as Float), MLXArray(0 as Float)).asType(dtype)
    }

    /// Token ids -> `[1, S, hiddenSize]` embeddings, the encoder's true input.
    ///
    /// The embedding table is bf16 in the model export and the stack runs fp32,
    /// so this upcasts once here rather than per layer.
    func embed(ids: [Int]) -> MLXArray {
        let idx = MLXArray(ids.map { Int32($0) })
        return embedTokens[idx].expandedDimensions(axis: 0).asType(.float32)
    }

    /// Text in, conditioning out — the whole encode span.
    ///
    /// Returns the tags alongside, because the packed layout needs a modality
    /// per text token and a pure-text prompt is not the only possible case.
    func encode(_ text: String, tokenizer: H3Tokenizer,
                       computeDType: DType = .float32)
        -> (cond: MLXArray, ids: [Int], tags: [Int]) {
        let ids = tokenizer.encodePrompt(text)
        let cond = callAsFunction(embeds: embed(ids: ids),
                                  computeDType: computeDType)
        return (cond, ids, tokenizer.textTags(count: ids.count))
    }

    /// Runs the language stack over pre-computed token embeddings.
    /// The encoder runs in fp32 by default while retaining the export's
    /// original weight dtype in memory.
    ///
    /// - Parameter embeds: `[1, S, hiddenSize]`
    /// - Returns: `[1, S, hiddenSize]` — the **unnormalized** layer-50 state.
    func callAsFunction(embeds: MLXArray,
                               computeDType: DType = .float32,
                               positionIds: MLXArray? = nil,
                               visualSpans: [(start: Int, count: Int)] = [],
                               deepstack: [MLXArray] = []) -> MLXArray {
        let s = embeds.dim(1)
        var h = embeds.asType(computeDType)
        // Three rows of position ids means an image is present; one row, or
        // none, is the text path.
        let (rc, rs) = positionIds.map { mrope(positionIds: $0, dtype: computeDType) }
                    ?? rope(count: s, dtype: computeDType)
        let mask = Self.causalMask(s, dtype: computeDType)
        let scale = 1.0 / Float(config.headDim).squareRoot()

        for (i, l) in layers.enumerated() {
            // attention
            let x = l.inputNorm(h)[0]                              // [S, hidden]
            var q = matmul(x, l.q.T).reshaped([s, config.numHeads, config.headDim])
            var k = matmul(x, l.k.T).reshaped([s, config.numKVHeads, config.headDim])
            let v = matmul(x, l.v.T).reshaped([s, config.numKVHeads, config.headDim])
            q = l.qNorm(q)
            k = l.kNorm(k)
            let qh = Self.applyRoPE(q.transposed(1, 0, 2).expandedDimensions(axis: 0),
                                    cos: rc, sin: rs)
            let kh = Self.applyRoPE(k.transposed(1, 0, 2).expandedDimensions(axis: 0),
                                    cos: rc, sin: rs)
            let vh = v.transposed(1, 0, 2).expandedDimensions(axis: 0)
            // MLX's SDPA handles the 64:8 grouping itself.
            let o = MLXFast.scaledDotProductAttention(queries: qh, keys: kh, values: vh,
                                                      scale: scale, mask: mask)
            let merged = o.squeezed(axis: 0).transposed(1, 0, 2)
                          .reshaped([s, config.innerDim])
            h = h + matmul(merged, l.o.T).expandedDimensions(axis: 0)

            // SwiGLU MLP
            let y = l.postAttnNorm(h)[0]
            let g = matmul(y, l.gate.T), u = matmul(y, l.up.T)
            h = h + matmul(silu(g) * u, l.down.T).expandedDimensions(axis: 0)

            // DeepStack: the vision tower's layer-8/16/24 features are *added*
            // into the first three language layers, at the image's token
            // positions only. Prefill only, which is all H3 ever does.
            //
            // The reference writes this as a boolean-mask scatter. Here the
            // spans are contiguous by construction, so rebuilding the row from
            // slices does the same job without a scatter kernel.
            if i < deepstack.count, !visualSpans.isEmpty {
                let row = h[0]
                var parts: [MLXArray] = []
                var prev = 0, off = 0
                for sp in visualSpans {
                    if sp.start > prev { parts.append(row[prev ..< sp.start]) }
                    parts.append(row[sp.start ..< (sp.start + sp.count)]
                                 + deepstack[i][off ..< (off + sp.count)].asType(computeDType))
                    prev = sp.start + sp.count
                    off += sp.count
                }
                if prev < s { parts.append(row[prev ..< s]) }
                h = concatenated(parts, axis: 0).expandedDimensions(axis: 0)
            }
            if i % 10 == 0 { eval(h) }
        }
        // No final norm: the H3 Base export does not carry one.
        return h
    }
}

// SPDX-License-Identifier: Apache-2.0


/// Builds the text-and-vision input consumed by the H3 Encoder in FL2VA.
///
/// A keyframe is sent through both Base condition paths: its semantic vision
/// tokens are inserted into the text sequence, while its Visual VAE latent is
/// inserted into the visual condition rows.
enum H3Presentation {
    private static let fallbackVisionStart = 151_652
    private static let fallbackVisionEnd = 151_653

    struct VisionBlock {
        let merged: MLXArray
        let deepstack: [MLXArray]

        init(merged: MLXArray, deepstack: [MLXArray]) {
            self.merged = merged
            self.deepstack = deepstack
        }

        var tokens: Int { merged.dim(0) }
    }

    struct Span: Sendable, Equatable {
        let start: Int
        let size: Int
        var end: Int { start + size }
    }

    struct Assembled {
        let embeds: MLXArray
        let spans: [Span]
        let positionIds: MLXArray?
        let visualMask: MLXArray?
        let deepstack: [MLXArray]
        let tags: [Int]
    }

    enum Element {
        case text(String)
        case vision(VisionBlock, H3VisionGrid)
    }

    /// Creates the FL2VA text stream: `<Picture N>` + vision block(s) + prompt.
    static func assemble(
        prompt: String,
        blocks: [VisionBlock],
        tokenizer: H3Tokenizer,
        encoder: H3TextEncoder,
        gridPerImage: [H3VisionGrid]
    ) -> Assembled {
        precondition(
            blocks.count == gridPerImage.count,
            "\(blocks.count) vision block(s) but \(gridPerImage.count) grid(s)")

        var elements: [Element] = []
        for (index, block) in blocks.enumerated() {
            elements.append(.text("<Picture \(index + 1)>: "))
            elements.append(.vision(block, gridPerImage[index]))
        }
        elements.append(.text(prompt))
        return assemble(elements: elements, tokenizer: tokenizer, encoder: encoder)
    }

    /// Creates an arbitrary H3 Encoder presentation while keeping every
    /// vision span in the exact order in which its label appears.
    static func assemble(
        elements: [Element],
        tokenizer: H3Tokenizer,
        encoder: H3TextEncoder
    ) -> Assembled {

        // These ids are part of tokenizer_config.json in the H3 repository.
        // Keep the historical ids only as a compatibility fallback for older
        // local snapshots that predate the added-token entry.
        let visionStart = tokenizer.tokenID(for: "<|vision_start|>")
            ?? fallbackVisionStart
        let visionEnd = tokenizer.tokenID(for: "<|vision_end|>")
            ?? fallbackVisionEnd

        var pieces: [MLXArray] = []
        var spans: [Span] = []
        var grids: [H3VisionGrid] = []
        var visionBlocks: [VisionBlock] = []
        var cursor = 0

        func appendText(_ text: String) {
            let ids = tokenizer.encode(text)
            guard !ids.isEmpty else { return }
            pieces.append(encoder.embed(ids: ids)[0])
            cursor += ids.count
        }

        func appendIds(_ ids: [Int]) {
            pieces.append(encoder.embed(ids: ids)[0])
            cursor += ids.count
        }

        func appendVision(_ block: VisionBlock, grid: H3VisionGrid) {
            appendIds([visionStart])
            spans.append(Span(start: cursor, size: block.tokens))
            grids.append(grid)
            visionBlocks.append(block)
            pieces.append(block.merged.asType(.float32))
            cursor += block.tokens
            appendIds([visionEnd])
        }

        for element in elements {
            switch element {
            case .text(let text):
                appendText(text)
            case .vision(let block, let grid):
                appendVision(block, grid: grid)
            }
        }
        if cursor == 0 {
            appendIds([H3Tokenizer.padToken])
        }

        let embeds = concatenated(pieces, axis: 0).expandedDimensions(axis: 0)
        let sequenceLength = embeds.dim(1)

        // The entire vision block, including its boundary tokens, is visual.
        var tags = [Int](repeating: 1, count: sequenceLength)
        for span in spans {
            for index in max(0, span.start - 1) ..< min(sequenceLength, span.end + 1) {
                tags[index] = 0
            }
        }

        guard !spans.isEmpty else {
            return Assembled(
                embeds: embeds,
                spans: [],
                positionIds: nil,
                visualMask: nil,
                deepstack: [],
                tags: tags)
        }

        var mask = [Int32](repeating: 0, count: sequenceLength)
        for span in spans {
            for index in span.start ..< span.end {
                mask[index] = 1
            }
        }

        let stackCount = visionBlocks.first?.deepstack.count ?? 0
        let deepstack = (0 ..< stackCount).map { layer in
            concatenated(
                visionBlocks.map { $0.deepstack[layer].asType(.float32) },
                axis: 0)
        }

        return Assembled(
            embeds: embeds,
            spans: spans,
            positionIds: positionIds(
                spans: spans,
                grids: grids,
                sequenceLength: sequenceLength),
            visualMask: MLXArray(mask),
            deepstack: deepstack,
            tags: tags)
    }

    /// Qwen vision RoPE positions with temporal, height and width axes.
    static func positionIds(
        spans: [Span],
        grids: [H3VisionGrid],
        sequenceLength: Int
    ) -> MLXArray {
        var rows = [[Float]](
            repeating: [Float](repeating: 0, count: sequenceLength),
            count: 3)
        var offset = 0
        var wroteHead = false

        for (span, grid) in zip(spans, grids) {
            if !wroteHead {
                for index in 0 ..< span.start {
                    for row in 0 ..< 3 {
                        rows[row][index] = Float(index)
                    }
                }
                wroteHead = true
            }

            let largestAxis = max(grid.t, max(grid.h, grid.w)) / 2
            let startNext = largestAxis + span.start

            for (index, position) in (span.end ..< sequenceLength).enumerated() {
                for row in 0 ..< 3 {
                    rows[row][position] = Float(startNext + offset + index)
                }
            }

            for index in span.start ..< span.end {
                rows[0][index] = Float(span.start + offset)
            }

            let mergedHeight = grid.h / 2
            let repeatHeight = (span.size + mergedHeight - 1) / mergedHeight
            for index in 0 ..< span.size {
                rows[1][span.start + index] = Float(
                    span.start + offset + index / repeatHeight)
            }

            let mergedWidth = grid.w / 2
            for index in 0 ..< span.size {
                rows[2][span.start + index] = Float(
                    span.start + offset + index % mergedWidth)
            }

            offset += largestAxis - span.size
        }

        return MLXArray(rows.flatMap { $0 }, [3, sequenceLength])
    }
}

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Kammerich


struct H3TextConditioningData {
    let textEmbeddings: MLXArray
    let tags: [Int]
    let tokenCount: Int
}

/// Encodes the text prompt and optional FL2VA images for H3 Base.
///
/// The H3 Encoder and the vision tower are both part of the public FL2VA
/// `text_encoder` component. A keyframe is represented twice, as required by
/// H3 Base: semantic vision tokens enter this text stream and the same image's
/// Visual VAE latent enters the visual condition stream.
enum H3TextConditioning {
    static func encodeFL2VA(
        prompt: String,
        request: H3EvaluatorRequest,
        hub: HubApi,
        configuration: H3Configuration,
        log: (String) -> Void = { _ in }
    ) throws -> H3TextConditioningData {
        let encoder = try H3TextEncoder(hub: hub, configuration: configuration)
        let tokenizer = try H3Tokenizer(hub: hub, configuration: configuration)
        let presented = request
            .resolvedKeyframes(frameCount: request.alignedFrameCount)
            .map(\.image)

        let positive: (cond: MLXArray, count: Int, tags: [Int])
        if presented.isEmpty {
            let encoded = encoder.encode(prompt, tokenizer: tokenizer)
            positive = (encoded.cond, encoded.ids.count, encoded.tags)
        } else {
            positive = try presentedConditioning(
                prompt: prompt,
                images: presented,
                hub: hub,
                configuration: configuration,
                encoder: encoder,
                tokenizer: tokenizer,
                log: log)
        }

        eval(positive.cond)
        log("  prompt -> \(positive.count) text tokens")
        return H3TextConditioningData(
            textEmbeddings: positive.cond,
            tags: positive.tags,
            tokenCount: positive.count)
    }

    private static func presentedConditioning(
        prompt: String,
        images: [URL],
        hub: HubApi,
        configuration: H3Configuration,
        encoder: H3TextEncoder,
        tokenizer: H3Tokenizer,
        log: (String) -> Void
    ) throws -> (cond: MLXArray, count: Int, tags: [Int]) {
        let tower = try H3VisionEncoder(hub: hub, configuration: configuration)

        func block(_ pixels: MLXArray) throws -> (H3Presentation.VisionBlock, H3VisionGrid) {
            let (gridWidth, gridHeight, grid) = H3VisionPreprocess.grid(
                width: pixels.dim(2),
                height: pixels.dim(1))
            guard gridWidth == pixels.dim(2), gridHeight == pixels.dim(1) else {
                throw H3EvaluatorError.mediaOffCanvas(
                    path: "frame conditioning",
                    size: "\(pixels.dim(2))x\(pixels.dim(1))",
                    remedy: "use an image whose dimensions are supported by H3's vision grid.")
            }
            let patches = try H3VisionPreprocess.patches(image: pixels, grid: grid)
            let encoded = tower(patches: patches, grid: grid)
            return (
                H3Presentation.VisionBlock(
                    merged: encoded.merged,
                    deepstack: encoded.deepstack),
                grid)
        }

        var blocks: [H3Presentation.VisionBlock] = []
        var grids: [H3VisionGrid] = []
        for image in images {
            let size = try H3IO.imageSize(at: image.path)
            let (gridWidth, gridHeight, _) = H3VisionPreprocess.grid(
                width: size.width,
                height: size.height)
            let pixels = try H3IO.imageHWC(
                at: image.path,
                width: gridWidth,
                height: gridHeight)
            let (vision, grid) = try block(pixels)
            blocks.append(vision)
            grids.append(grid)
            log("    \(image.lastPathComponent): \(gridWidth)x\(gridHeight) -> "
                + "\(vision.merged.dim(0)) vision tokens")
        }

        let assembled = H3Presentation.assemble(
            prompt: prompt,
            blocks: blocks,
            tokenizer: tokenizer,
            encoder: encoder,
            gridPerImage: grids)
        let encoded = encoder(
            embeds: assembled.embeds,
            computeDType: .float32,
            positionIds: assembled.positionIds,
            visualSpans: assembled.spans.map { (start: $0.start, count: $0.size) },
            deepstack: assembled.deepstack)
        return (encoded, assembled.embeds.dim(1), assembled.tags)
    }
}

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Kammerich


/// Encoded visual and audio conditions consumed by the H3 Omni Transformer.
