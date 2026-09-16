//
//  H3Encoder.swift
//  ModelCraft
//
//  Created by Hongshen on 27/8/26.
//


import Foundation
import Hub
import MLX
import MLXFast
import MLXNN


/// The composed H3 Encoder component.
///
/// MiniMax packages the Qwen3-VL language stack and vision tower in the same
/// `text_encoder` checkpoint. Keeping them together here lets ``H3Base`` own one
/// paper-level encoder while both halves read from one checkpoint.
///
/// **`init` reads nothing.** It holds where the checkpoint is, plus whichever
/// halves ``H3Loader/loadEncoder(hub:configuration:)`` already built for this
/// machine — none of them unless its profile reads components whole. What is left
/// out is built the first time a render asks for it, and the 2.75 GB of tensors
/// that are neither language layers are read once, on the first ask from either
/// half.
///
/// That is what makes a prompt pay only for what it uses: a text-only render
/// never builds the vision tower, and neither half is touched at all until the
/// conditioning stage reaches it.
///
/// Residency is mutable state on a `@unchecked Sendable` class, so one instance
/// must not serve two renders at once — the same rule ``H3Base`` states for
/// itself.
final class H3Encoder: @unchecked Sendable {
    /// Where the `text_encoder` checkpoint lives. Handed to
    /// ``H3Loader`` when a half is loaded; the URL is resolved there from the
    /// configuration's file keys rather than carried around.
    private let hub: HubApi
    let configuration: H3Configuration

    /// Everything that is not a language layer: the embedding table and the
    /// vision tower. Read on the first ask from either half; 2.75 GB.
    private var globals: [String: MLXArray]?
    /// The language half: the embedding table and the layer stack's tensor names.
    ///
    /// Read on first use. The language layers themselves are not here — they are
    /// 62.41 GB and ``H3TextEncoder/encode(embeds:computeDType:positionIds:visualSpans:deepstack:)`` reads each one as the pass
    /// reaches it.
    private var textEncoder: H3TextEncoder?
    /// The vision half: the 27-block tower over an image or a sampled video.
    ///
    /// Read on first use, so a prompt that carries no image never pays for it.
    private var visionEncoder: H3VisionEncoder?

    /// Holds where the checkpoint is, and whichever halves are already built.
    ///
    /// The three pieces are nil until something reads them. ``H3Loader/loadEncoder``
    /// passes all three when the machine's profile reads components whole, and
    /// passes none of them otherwise, so the first use of either half fills it —
    /// see the four callers in ``encodeText(elements:tokenizer:)``,
    /// ``encodePrompt(_:tokenizer:)``, ``encodeVisual(pixels:)`` and
    /// ``encodeVideo(frames:)``.
    init(
        hub: HubApi,
        configuration: H3Configuration,
        globals: [String: MLXArray]? = nil,
        textEncoder: H3TextEncoder? = nil,
        visionEncoder: H3VisionEncoder? = nil
    ) {
        self.hub = hub
        self.configuration = configuration
        self.globals = globals
        self.textEncoder = textEncoder
        self.visionEncoder = visionEncoder
    }

    // MARK: - Text

    /// The language stack over a Ref2VA prompt: references folded into the text
    /// span in the order they were given.
    ///
    /// Ordering, embedding and the layer walk all happen here, so a caller
    /// describes the prompt's pieces and never touches either half.
    func encodeText(
        elements: [H3Presentation.Element],
        tokenizer: H3Tokenizer
    ) throws -> (conditioning: MLXArray, tags: [Int]) {
        let globals = try globals
            ?? H3Loader.loadEncoderGlobals(hub: hub, configuration: configuration)
        let textEncoder = try self.textEncoder
            ?? H3Loader.loadTextEncoder(
                globals: globals, hub: hub, configuration: configuration)
        self.globals = globals
        self.textEncoder = textEncoder

        let assembled = H3Presentation.assemble(
            elements: elements, tokenizer: tokenizer, encoder: textEncoder)
        return try (run(assembled, on: textEncoder), assembled.tags)
    }

    /// The language stack over an FL2VA prompt: `<Picture N>` + block(s) + prompt.
    ///
    /// The labelling is the whole of FL2VA's text layout; everything past it is
    /// the same presentation the Ref2VA path builds.
    func encodeText(
        prompt: String,
        blocks: [H3Presentation.VisionBlock],
        tokenizer: H3Tokenizer,
        gridPerImage: [H3VisionGrid]
    ) throws -> (conditioning: MLXArray, tags: [Int]) {
        precondition(
            blocks.count == gridPerImage.count,
            "\(blocks.count) vision block(s) but \(gridPerImage.count) grid(s)")

        var elements: [H3Presentation.Element] = []
        for (index, block) in blocks.enumerated() {
            elements.append(.text("<Picture \(index + 1)>: "))
            elements.append(.vision(block, gridPerImage[index]))
        }
        elements.append(.text(prompt))
        return try encodeText(elements: elements, tokenizer: tokenizer)
    }

    /// The language stack over a bare prompt: no images, so no vision spans and
    /// no deepstack.
    ///
    /// A prompt on its own is tokenised by the tokenizer's prompt path rather
    /// than the plain text encoding the vision path uses, so this is not just
    /// ``encodeText(elements:tokenizer:)`` with one element.
    func encodePrompt(
        _ prompt: String,
        tokenizer: H3Tokenizer
    ) throws -> (conditioning: MLXArray, tags: [Int]) {
        let globals = try globals
            ?? H3Loader.loadEncoderGlobals(hub: hub, configuration: configuration)
        let textEncoder = try self.textEncoder
            ?? H3Loader.loadTextEncoder(
                globals: globals, hub: hub, configuration: configuration)
        self.globals = globals
        self.textEncoder = textEncoder

        let ids = tokenizer.encodePrompt(prompt)
        return (try textEncoder.encode(embeds: textEncoder.embed(ids: ids)),
                tokenizer.textTags(count: ids.count))
    }

    /// The one place an assembled prompt becomes hidden state.
    private func run(
        _ assembled: H3Presentation.Assembled,
        on textEncoder: H3TextEncoder
    ) throws -> MLXArray {
        try textEncoder.encode(
            embeds: assembled.embeds,
            positionIds: assembled.positionIds,
            visualSpans: assembled.spans.map { (start: $0.start, count: $0.size) },
            deepstack: assembled.deepstack)
    }

    // MARK: - Visual

    /// An image reference through the vision tower.
    ///
    /// The image must already sit on H3's 32-pixel vision grid — resizing belongs
    /// to whoever decoded the file — so this only packs, encodes and hands back
    /// the block a prompt splices in, with the grid it covers.
    func encodeVisual(
        pixels: MLXArray
    ) throws -> (block: H3Presentation.VisionBlock, grid: H3VisionGrid) {
        let (width, height, grid) = H3VisionPreprocess.grid(
            width: pixels.dim(2),
            height: pixels.dim(1))
        guard width == pixels.dim(2), height == pixels.dim(1) else {
            throw H3EvaluatorError.mediaOffCanvas(
                path: "image reference",
                size: "\(pixels.dim(2))x\(pixels.dim(1))",
                remedy: "decode the reference on H3's 32-pixel vision grid.")
        }
        let globals = try globals
            ?? H3Loader.loadEncoderGlobals(hub: hub, configuration: configuration)
        let visionEncoder = try self.visionEncoder
            ?? H3Loader.loadVisionEncoder(globals: globals)
        self.globals = globals
        self.visionEncoder = visionEncoder

        let encoded = visionEncoder(
            patches: try H3VisionPreprocess.patches(image: pixels, grid: grid),
            grid: grid)
        return (H3Presentation.VisionBlock(
                    merged: encoded.merged, deepstack: encoded.deepstack), grid)
    }

    /// A sampled reference video through the vision tower: one block per temporal
    /// group, in order, each covering a single grid.
    ///
    /// The frames arrive already sampled — the reference's 2 fps grouping belongs
    /// to whoever read the file — so this packs, encodes and splits.
    func encodeVideo(
        frames: [MLXArray]
    ) throws -> [(block: H3Presentation.VisionBlock, grid: H3VisionGrid)] {
        let config = H3VisionEncoderConfiguration()
        let frameTensor = concatenated(frames, axis: 0)
        let (_, _, imageGrid) = H3VisionPreprocess.grid(
            width: frameTensor.dim(2),
            height: frameTensor.dim(1),
            config: config)
        let grid = H3VisionGrid(
            t: (frames.count + config.temporalPatchSize - 1) / config.temporalPatchSize,
            h: imageGrid.h,
            w: imageGrid.w)
        guard grid.t > 0 else { return [] }

        let globals = try globals
            ?? H3Loader.loadEncoderGlobals(hub: hub, configuration: configuration)
        let visionEncoder = try self.visionEncoder
            ?? H3Loader.loadVisionEncoder(globals: globals)
        self.globals = globals
        self.visionEncoder = visionEncoder

        let encoded = visionEncoder(
            patches: try H3VisionPreprocess.patches(
                video: frameTensor, grid: grid, config: config),
            grid: grid)

        let tokensPerBlock = encoded.merged.dim(0) / grid.t
        return (0 ..< grid.t).map { blockIndex in
            let range = (blockIndex * tokensPerBlock) ..< ((blockIndex + 1) * tokensPerBlock)
            return (H3Presentation.VisionBlock(
                        merged: encoded.merged[range],
                        deepstack: encoded.deepstack.map { $0[range] }),
                    H3VisionGrid(t: 1, h: grid.h, w: grid.w))
        }
    }
}

/// The Qwen3-VL language stack, minus the layers themselves.
///
/// 62.41 GB of the encoder's 66.71 GB is the 64 language layers, so ``layers``
/// holds a slot per layer and nothing more: ``encode(embeds:computeDType:positionIds:visualSpans:deepstack:)`` fills the slot as
/// the pass reaches it and empties it on the way past. What lives here — the
/// embedding table and the tensor name prefix — is read once per render rather
/// than once per layer.
final class H3TextEncoder {
    let config: H3TextEncoderConfiguration
    /// `model.language_model.` or `model.`, detected from the checkpoint.
    ///
    /// Kept as state because a layer's tensor names are built from it at run
    /// time, long after the key scan that discovered it.
    let prefix: String
    let embedTokens: MLXArray
    private let hub: HubApi
    let configuration: H3Configuration
    private var url: URL {
        get throws { try H3Loader.resolve(
            hub: hub, configuration: configuration, key: .textEncoderWeights) }
    }
    /// The language stack. `layers[i]` is layer `i` while it is in memory and
    /// `nil` when it is not.
    ///
    /// The stack is 62.41 GB, so it is never all here. One pass walks it front to
    /// back and never returns to a layer, so ``encode(embeds:computeDType:positionIds:visualSpans:deepstack:)`` gives each one back
    /// as it moves on and at most one is resident at a time.
    private var layers: [H3TextEncoderLayer?]

    /// Builds the language stack around the embedding and resolved layer prefix
    /// supplied by ``H3Loader/loadTextEncoder(globals:hub:configuration:)``.
    init(
        embedTokens: MLXArray,
        prefix: String,
        hub: HubApi,
        configuration: H3Configuration,
        config: H3TextEncoderConfiguration
    ) {
        self.config = config
        self.prefix = prefix
        self.embedTokens = embedTokens
        self.hub = hub
        self.configuration = configuration
        self.layers = Array(repeating: nil, count: config.numLayers)
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

    /// One pass over the language stack, and everything the layers read from.
    ///
    /// The RoPE table, causal mask and attention scale depend on the sequence
    /// length, not on the layer, so they are built once here and handed to every
    /// layer the walk reaches.
    private struct Pass {
        fileprivate let s: Int
        fileprivate let rc: MLXArray
        fileprivate let rs: MLXArray
        fileprivate let mask: MLXArray?
        fileprivate let scale: Float
        fileprivate let deepstack: [MLXArray]
        fileprivate let visualSpans: [(start: Int, count: Int)]
        fileprivate let computeDType: DType
        /// The rows entering the stack, `[1, S, hiddenSize]`.
        let h: MLXArray
    }

    /// Runs the whole language stack over one pass's embeddings.
    ///
    /// This is the text encoder's one entry point: it builds the pass and walks
    /// every layer, reading each one as the walk reaches it. The two halves are
    /// never used apart — a pass describes one sequence, and the stack is run
    /// over that sequence exactly once — so they are not two calls here.
    ///
    /// - Parameter embeds: `[1, S, hiddenSize]`
    /// - Returns: `[1, S, hiddenSize]` — the **unnormalized** layer-`config.numLayers`
    ///   state. No final norm: the H3 Base export does not carry one.
    func encode(
        embeds: MLXArray,
        computeDType: DType = .float32,
        positionIds: MLXArray? = nil,
        visualSpans: [(start: Int, count: Int)] = [],
        deepstack: [MLXArray] = []
    ) throws -> MLXArray {
        try runStack(begin(
            embeds: embeds,
            computeDType: computeDType,
            positionIds: positionIds,
            visualSpans: visualSpans,
            deepstack: deepstack))
    }

    /// Opens the language stack over pre-computed token embeddings.
    ///
    /// The encoder runs in fp32 by default while retaining the export's original
    /// weight dtype in memory.
    ///
    /// - Parameter embeds: `[1, S, hiddenSize]`
    private func begin(embeds: MLXArray,
                       computeDType: DType = .float32,
                       positionIds: MLXArray? = nil,
                       visualSpans: [(start: Int, count: Int)] = [],
                       deepstack: [MLXArray] = []) -> Pass {
        let s = embeds.dim(1)
        // Three rows of position ids means an image is present; one row, or
        // none, is the text path.
        let (rc, rs) = positionIds.map { mrope(positionIds: $0, dtype: computeDType) }
                    ?? rope(count: s, dtype: computeDType)
        return Pass(
            s: s,
            rc: rc,
            rs: rs,
            mask: Self.causalMask(s, dtype: computeDType),
            scale: 1.0 / Float(config.headDim).squareRoot(),
            deepstack: deepstack,
            visualSpans: visualSpans,
            computeDType: computeDType,
            h: embeds.asType(computeDType))
    }

    /// Runs one layer of the stack on the pass's hidden state.
    ///
    /// This is the only place a layer is invoked, so there is no second
    /// arithmetic path for a layer to disagree with itself about.
    private func run(_ layer: H3TextEncoderLayer, index i: Int, _ pass: Pass,
                     h: MLXArray) -> MLXArray {
        advance(layer, index: i, h: h, s: pass.s, rc: pass.rc, rs: pass.rs,
                mask: pass.mask, scale: pass.scale,
                deepstack: pass.deepstack, visualSpans: pass.visualSpans,
                computeDType: pass.computeDType)
    }

    /// Runs the whole language stack over one pass's embeddings, reading each
    /// layer as the walk reaches it.
    ///
    /// - Returns: `[1, S, hiddenSize]` — the **unnormalized** layer-`numLayers`
    ///   state. No final norm: the H3 Base export does not carry one.
    private func runStack(_ pass: Pass) throws -> MLXArray {
        var h = pass.h
        for index in 0 ..< config.numLayers {
            if layers[index] == nil {
                layers[index] = try H3Loader.loadTextEncoderLayer(
                    index: index, url: try url, prefix: prefix, config: config)
            }
            h = run(layers[index]!, index: index, pass, h: h)
            // Nothing reads a language layer twice, so it goes as the walk leaves
            // it: holding one would keep 975 MB alive for a reader that never
            // comes.
            layers[index] = nil
        }
        return h
    }

    /// One layer: attention, SwiGLU, then the deepstack injection.
    private func advance(
        _ l: H3TextEncoderLayer, index i: Int, h: MLXArray, s: Int,
        rc: MLXArray, rs: MLXArray, mask: MLXArray?, scale: Float,
        deepstack: [MLXArray], visualSpans: [(start: Int, count: Int)],
        computeDType: DType
    ) -> MLXArray {
        // attention
        let attn = l.selfAttn
        let x = l.inputNorm(h)[0]                                  // [S, hidden]
        var q = attn.q(x).reshaped([s, config.numHeads, config.headDim])
        var k = attn.k(x).reshaped([s, config.numKVHeads, config.headDim])
        let v = attn.v(x).reshaped([s, config.numKVHeads, config.headDim])
        q = attn.qNorm(q)
        k = attn.kNorm(k)
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
        let attended = h + attn.o(merged).expandedDimensions(axis: 0)

        // SwiGLU MLP
        let mlp = l.mlp
        let y = l.postAttnNorm(attended)[0]
        let g = mlp.gate(y), u = mlp.up(y)
        var updated = attended + mlp.down(silu(g) * u).expandedDimensions(axis: 0)

        // DeepStack: the vision tower's layer-8/16/24 features are *added*
        // into the first three language layers, at the image's token
        // positions only. Prefill only, which is all H3 ever does.
        //
        // The reference writes this as a boolean-mask scatter. Here the
        // spans are contiguous by construction, so rebuilding the row from
        // slices does the same job without a scatter kernel.
        if i < deepstack.count, !visualSpans.isEmpty {
            let row = updated[0]
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
            updated = concatenated(parts, axis: 0).expandedDimensions(axis: 0)
        }
        return updated
    }
}

/// One layer of the text encoder's language stack.
///
/// The stack is nearly all of the encoder's 66.71 GB and is never resident, so a
/// layer is the unit a caller loads, runs and lets go of —
/// see ``H3TextEncoderConfiguration/numLayers`` for how many the walk reads.
///
/// A `Module` whose parts are declared one level per level of the checkpoint's
/// names, so ``H3Loader/loadTextEncoderLayer(index:url:prefix:config:)`` fills the
/// declaration from the slice of the shard that holds layer `i` — the names and
/// the structure are the same statement. That matters more here than elsewhere: a
/// mis-wiring yields a plausible hidden state rather than an error, and the whole
/// render would be subtly wrong with nothing to point at.
final class H3TextEncoderLayer: Module {
    @ModuleInfo(key: "input_layernorm") var inputNorm: H3RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttnNorm: H3RMSNorm
    @ModuleInfo(key: "self_attn") var selfAttn: H3TextEncoderAttention
    @ModuleInfo var mlp: H3TextEncoderMLP

    /// The declaration, with every parameter present but unread. See
    /// ``H3VisionEncoder/init(config:)`` for why the shapes have to be allocated
    /// before `update` runs.
    init(config: H3TextEncoderConfiguration) {
        self._inputNorm.wrappedValue = H3RMSNorm(
            dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._postAttnNorm.wrappedValue = H3RMSNorm(
            dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._selfAttn.wrappedValue = H3TextEncoderAttention(config: config)
        self._mlp.wrappedValue = H3TextEncoderMLP(config: config)
    }
}

/// `self_attn` — grouped-query attention, with a norm on the queries and keys.
///
/// The four projections carry no bias, which is why each is a `weight` in the
/// checkpoint and nothing else.
final class H3TextEncoderAttention: Module {
    @ModuleInfo(key: "q_proj") var q: Linear
    @ModuleInfo(key: "k_proj") var k: Linear
    @ModuleInfo(key: "v_proj") var v: Linear
    @ModuleInfo(key: "o_proj") var o: Linear
    @ModuleInfo(key: "q_norm") var qNorm: H3RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: H3RMSNorm

    init(config: H3TextEncoderConfiguration) {
        self._q.wrappedValue = Linear(config.hiddenSize, config.innerDim, bias: false)
        self._k.wrappedValue = Linear(config.hiddenSize, config.kvDim, bias: false)
        self._v.wrappedValue = Linear(config.hiddenSize, config.kvDim, bias: false)
        self._o.wrappedValue = Linear(config.innerDim, config.hiddenSize, bias: false)
        self._qNorm.wrappedValue = H3RMSNorm(dimensions: config.headDim, eps: config.rmsNormEps)
        self._kNorm.wrappedValue = H3RMSNorm(dimensions: config.headDim, eps: config.rmsNormEps)
    }
}

/// `mlp` — the SwiGLU feed-forward.
final class H3TextEncoderMLP: Module {
    @ModuleInfo(key: "gate_proj") var gate: Linear
    @ModuleInfo(key: "up_proj") var up: Linear
    @ModuleInfo(key: "down_proj") var down: Linear

    init(config: H3TextEncoderConfiguration) {
        self._gate.wrappedValue = Linear(
            config.hiddenSize, config.intermediateSize, bias: false)
        self._up.wrappedValue = Linear(
            config.hiddenSize, config.intermediateSize, bias: false)
        self._down.wrappedValue = Linear(
            config.intermediateSize, config.hiddenSize, bias: false)
    }
}

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


struct H3VisionGrid: Sendable, Equatable {
    let t: Int, h: Int, w: Int
    init(t: Int = 1, h: Int, w: Int) { self.t = t; self.h = h; self.w = w }
    var tokens: Int { t * h * w }
}

/// The Qwen3-VL vision tower: 27 blocks that turn an image into tokens for the
/// language stack, plus the four mergers that project them into its width.
///
/// A `Module` whose parts are declared rather than built from a dictionary of
/// tensors. ``H3Loader/loadVisionEncoder(globals:)`` translates the checkpoint's
/// names and fills this structure.
///
/// It is not split into separately-loaded layers the way the language stack and
/// the DiT are. Its 27 blocks are 824 MB and live together in the `text_encoder`
/// checkpoint's last shard, so there is one file to open and nothing to gain from
/// opening it 27 times: the whole tower is small enough to read at once, and it
/// is, all 351 of its tensors.
///
/// Reachable only through **image prompts**. It has nothing to do with I2V
/// keyframes, which go through the Visual VAE; confusing the two is easy because
/// both take an image and both feed the DiT.
final class H3VisionEncoder: Module {
    let config: H3VisionEncoderConfiguration

    @ModuleInfo(key: "patch_embed") var patchEmbed: H3VisionPatchEmbed
    @ModuleInfo(key: "pos_embed") var posEmbed: Embedding
    @ModuleInfo(key: "deepstack_merger_list") var deepstackMergers: [H3VisionMerger]
    @ModuleInfo var blocks: [H3VisionBlock]
    @ModuleInfo var merger: H3VisionMerger

    /// Declares the vision tower and each parameter's shape without evaluating
    /// the placeholder arrays.
    init(config: H3VisionEncoderConfiguration = H3VisionEncoderConfiguration()) {
        self.config = config
        self._patchEmbed.wrappedValue = H3VisionPatchEmbed(config: config)
        // A learned 48x48 grid to be resampled per image. It is indexed, not
        // projected, so it is an `Embedding`.
        self._posEmbed.wrappedValue = Embedding(
            weight: MLXArray.zeros([config.numPositionEmbeddings, config.hiddenSize]))
        self._blocks.wrappedValue = (0 ..< config.depth).map { _ in
            H3VisionBlock(config: config)
        }
        self._merger.wrappedValue = H3VisionMerger(config: config, postShuffleNorm: false)
        self._deepstackMergers.wrappedValue = config.deepstackIndexes.map { _ in
            H3VisionMerger(config: config, postShuffleNorm: true)
        }
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
            let e = posEmbed.weight[idx.flattened()] * weight.flattened().reshaped([-1, 1])
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
        // The convolution is a matmul here; see ``H3VisionPatchEmbed/Projection``.
        let patchProj = patchEmbed.proj
        var x = matmul(
            patches.asType(.float32),
            patchProj.weight.reshaped([config.hiddenSize, -1]).T) + patchProj.bias
        x = x + positionEmbeddings(grid)

        let freqs = ropeFrequencies(grid)                        // [S, rotaryDim]
        let c = cos(freqs).expandedDimensions(axis: 1)           // [S, 1, rotaryDim]
        let sn = sin(freqs).expandedDimensions(axis: 1)

        // Only the tapped blocks are read back out once the stack has run, so
        // only those are kept. Holding all 27 hidden states would cost about
        // 450 MB per image for the 24 that nothing looks at.
        var tapped: [Int: MLXArray] = [:]
        // Attention runs per image. H3 sends one image at a time, so there is a
        // single segment and no mask is needed — the reference splits on
        // `cu_seqlens` for exactly this reason and would need a block-diagonal
        // mask if it did not.
        let scale = 1.0 / Float(config.headDim).squareRoot()
        for (i, block) in blocks.enumerated() {
            let h = block.norm1(x)
            let qkv = block.attn.qkv(h)
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
            x = x + block.attn.proj(attn)

            let y = block.norm2(x)
            // GELU is the tanh approximation throughout this tower.
            x = x + block.mlp.fc2(geluApproximate(block.mlp.fc1(y)))
            if config.deepstackIndexes.contains(i) { tapped[i] = x }
            // The cadence is deliberate: it bounds the graph the tower builds
            // without forcing a pass per block.
            if i % 10 == 0 { eval(x) }
        }

        var deepstack: [MLXArray] = []
        for (slot, layer) in config.deepstackIndexes.enumerated() {
            guard let feat = tapped[layer] else { continue }
            deepstack.append(apply(deepstackMergers[slot], feat))
        }
        return Output(merged: apply(merger, x), deepstack: deepstack)
    }

    /// Split-half rotation over the full head dim.
    ///
    /// The reference builds `emb = cat(rot, rot)` and then splits cos/sin back
    /// in half, so both halves see the same angle — which is plain rotate-half
    /// RoPE written the long way round.
    static func applyRoPE(_ x: MLXArray, cos c: MLXArray, sin s: MLXArray) -> MLXArray {
        let half = x.dim(-1) / 2
        let lo = x[.ellipsis, 0 ..< half]
        let hi = x[.ellipsis, half ..< (2 * half)]
        return concatenated([lo * c - hi * s, hi * c + lo * s], axis: -1)
    }

    /// `fc2(gelu(fc1(norm(x))))` with the merge reshape either side of the norm.
    private func apply(_ m: H3VisionMerger, _ x: MLXArray) -> MLXArray {
        let merged = m.postShuffleNorm
            ? m.norm(x.reshaped([-1, config.mergeDim]))          // norm after merge
            : m.norm(x).reshaped([-1, config.mergeDim])          // norm before merge
        return m.fc2(geluApproximate(m.fc1(merged)))
    }
}

/// One of the tower's 27 blocks: 30.5 MB of attention and GELU MLP.
///
/// The four names below are the checkpoint's; each one is a level of the path
/// its tensors live at.
final class H3VisionBlock: Module {
    @ModuleInfo var norm1: VaeLayerNorm
    @ModuleInfo var norm2: VaeLayerNorm
    @ModuleInfo var attn: H3VisionAttention
    @ModuleInfo var mlp: H3VisionFeedForward

    init(config: H3VisionEncoderConfiguration) {
        self._norm1.wrappedValue = VaeLayerNorm(dimensions: config.hiddenSize, eps: 1e-6)
        self._norm2.wrappedValue = VaeLayerNorm(dimensions: config.hiddenSize, eps: 1e-6)
        self._attn.wrappedValue = H3VisionAttention(config: config)
        self._mlp.wrappedValue = H3VisionFeedForward(config: config)
    }
}

/// `attn` — the fused QKV projection and the output projection.
final class H3VisionAttention: Module {
    @ModuleInfo var qkv: Linear
    @ModuleInfo var proj: Linear

    init(config: H3VisionEncoderConfiguration) {
        self._qkv.wrappedValue = Linear(config.hiddenSize, 3 * config.hiddenSize)
        self._proj.wrappedValue = Linear(config.hiddenSize, config.hiddenSize)
    }
}

/// `mlp` — the tower's GELU feed-forward.
///
/// `linear_fc1` and `linear_fc2` are the checkpoint's names for the two
/// projections; each carries its own `weight` and `bias` below them.
final class H3VisionFeedForward: Module {
    @ModuleInfo(key: "linear_fc1") var fc1: Linear
    @ModuleInfo(key: "linear_fc2") var fc2: Linear

    init(config: H3VisionEncoderConfiguration) {
        self._fc1.wrappedValue = Linear(config.hiddenSize, config.intermediateSize)
        self._fc2.wrappedValue = Linear(config.intermediateSize, config.hiddenSize)
    }
}

/// One of the tower's four mergers: the spatial merge up to the language model's
/// width, then a two-layer projection.
///
/// The main merger and the three deepstack mergers differ in **where the norm
/// sits**, and the model export says so: `merger.norm.weight` is `[1152]`, the
/// deepstack ones `[4608]`. The main merger normalizes each patch *before* the
/// spatial merge; deepstack normalizes the merged 4x vector *after*. Same weight
/// names, different semantics — which is why the flag is the thing that tells
/// them apart and not something the tensors say.
final class H3VisionMerger: Module {
    @ModuleInfo var norm: VaeLayerNorm
    @ModuleInfo(key: "linear_fc1") var fc1: Linear
    @ModuleInfo(key: "linear_fc2") var fc2: Linear

    /// Not a parameter — `update` never sees it — but the flag that decides which
    /// of the two mergers this is. The tensors cannot say: the names are the same
    /// and only the norm's width differs.
    let postShuffleNorm: Bool

    init(config: H3VisionEncoderConfiguration, postShuffleNorm: Bool) {
        self.postShuffleNorm = postShuffleNorm
        self._norm.wrappedValue = VaeLayerNorm(
            dimensions: postShuffleNorm ? config.mergeDim : config.hiddenSize, eps: 1e-6)
        self._fc1.wrappedValue = Linear(config.mergeDim, config.mergeDim)
        self._fc2.wrappedValue = Linear(config.mergeDim, config.outHiddenSize)
    }
}

/// `patch_embed` — the convolution that turns each patch into a token.
///
/// It has one child, `proj`, which is the convolution itself; the two levels are
/// kept because they are two levels of the checkpoint's own path.
final class H3VisionPatchEmbed: Module {
    /// `proj` — a `Conv3d` whose stride equals its kernel, applied to inputs that
    /// are already one patch each, so it is a matmul wearing a convolution's
    /// shape.
    ///
    /// Held as a weight and a bias rather than given to MLX as a convolution: the
    /// checkpoint stores it in PyTorch's `[out, in, kD, kH, kW]` order and MLX's
    /// `Conv3d` wants `[out, kD, kH, kW, in]`. `[1152, 3, 2, 16, 16]` flattens to
    /// `[1152, 1536]`, which is exactly the width of a `flatten_patches` row, and
    /// the flatten is a view — it costs nothing and happens where it is used.
    final class Projection: Module {
        @ParameterInfo var weight: MLXArray
        @ParameterInfo var bias: MLXArray

        init(weight: MLXArray, bias: MLXArray) {
            self._weight.wrappedValue = weight
            self._bias.wrappedValue = bias
        }
    }

    @ModuleInfo(key: "proj") var proj: Projection

    init(config: H3VisionEncoderConfiguration) {
        self._proj.wrappedValue = Projection(
            weight: MLXArray.zeros([
                config.hiddenSize, config.inChannels,
                config.temporalPatchSize, config.patchSize, config.patchSize,
            ]),
            bias: MLXArray.zeros([config.hiddenSize]))
    }
}


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


struct H3TextConditioningData {
    let textEmbeddings: MLXArray
    let tags: [Int]
}

/// Encodes the text prompt and optional FL2VA images for H3 Base.
///
/// The H3 Encoder and the vision tower are both part of the public FL2VA
/// `text_encoder` component. A keyframe is represented twice, as required by
/// H3 Base: semantic vision tokens enter this text stream and the same image's
/// Visual VAE latent enters the visual condition stream.
extension H3Conditioning {
    static func encodeFL2VA(
        prompt: String,
        keyframes: [H3EvaluatorKeyframe],
        encoder: H3Encoder,
        tokenizer: H3Tokenizer
    ) throws -> H3TextConditioningData {
        let presented = keyframes.map(\.image)

        let positive: (conditioning: MLXArray, tags: [Int])
        if presented.isEmpty {
            positive = try encoder.encodePrompt(prompt, tokenizer: tokenizer)
        } else {
            // A keyframe is presented twice: its vision tokens enter the text
            // stream here, and its Visual VAE latent enters the condition rows.
            positive = try presentedConditioning(
                prompt: prompt,
                images: presented,
                encoder: encoder,
                tokenizer: tokenizer)
        }

        eval(positive.conditioning)
        return H3TextConditioningData(
            textEmbeddings: positive.conditioning,
            tags: positive.tags)
    }

    private static func presentedConditioning(
        prompt: String,
        images: [URL],
        encoder: H3Encoder,
        tokenizer: H3Tokenizer
    ) throws -> (conditioning: MLXArray, tags: [Int]) {
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
            let (block, grid) = try encoder.encodeVisual(pixels: pixels)
            blocks.append(block)
            grids.append(grid)
        }

        return try encoder.encodeText(
            prompt: prompt, blocks: blocks, tokenizer: tokenizer, gridPerImage: grids)
    }
}
