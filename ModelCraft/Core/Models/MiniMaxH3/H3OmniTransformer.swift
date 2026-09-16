//
//  H3OmniTransformer.swift
//  ModelCraft
//
//  Created by Hongshen on 27/8/26.
//


import Foundation
import Hub
import MLX
import MLXFast
import MLXNN

/// The Omni Transformer: the DiT that denoises video and audio together.
///
/// A `Module` whose parts are declared under the checkpoint's own names, so
/// ``H3Loader/loadOmniTransformer(hub:configuration:computeDType:report:)``
/// fills them with `update(parameters:)`. The names are the diffusers export's,
/// which nests a one-element list and a two-stage feed-forward where the model
/// has a projection and an MLP; the loader folds those differences before the
/// parameters reach this module.
///
/// The layer stack is the exception and is not declared here. Its 50 layers are
/// 64.56 GB, so ``layers`` holds a slot per layer and nothing more:
/// ``runStack(_:)`` reads each one as a step reaches it.
final class H3OmniTransformer: Module {
    /// Immutable tensors shared by every denoise step of one render.
    ///
    /// The conditioning projection/refiner and RoPE table depend on the prompt
    /// and packed geometry, not on sigma or the evolving latents. Keeping them
    /// alive avoids rebuilding the position table and re-reading the refiner's
    /// weights on every step. It is deliberately supplied by the caller rather
    /// than kept as mutable state on the model: one model may serve multiple
    /// prompts or geometries without a stale-cache hazard.
    final class RenderState: @unchecked Sendable {
        fileprivate let layout: H3Sequence
        fileprivate let textTokenCount: Int
        fileprivate let textStates: MLXArray
        fileprivate let refined: MLXArray
        fileprivate let ropeTable: MLXArray

        fileprivate init(layout: H3Sequence, textTokenCount: Int,
                         textStates: MLXArray, refined: MLXArray, ropeTable: MLXArray) {
            self.layout = layout
            self.textTokenCount = textTokenCount
            self.textStates = textStates
            self.refined = refined
            self.ropeTable = ropeTable
        }
    }

    let config: H3Configuration

    /// Everything outside the layer stack, declared one level per level of the
    /// checkpoint's names. 1.72 GB, read once per render.
    @ModuleInfo(key: "context_embedder") var conditionProj: H3Projection
    @ModuleInfo(key: "proj_in") var videoPatchProj: H3Projection
    @ModuleInfo(key: "audio_proj_in") var audioPatchProj: H3Projection
    @ModuleInfo(key: "token_refiner") var tokenRefiner: TokenRefiner
    @ModuleInfo(key: "time_embedder") var timeEmbedder: TimeEmbedder
    /// `norm_out` — the output norm and the AdaLN that modulates it.
    @ModuleInfo(key: "norm_out") var outputLayer: H3OutputLayer
    /// The two output heads. They sit beside `norm_out` rather than under it.
    @ModuleInfo(key: "proj_out") var videoOut: H3Projection
    @ModuleInfo(key: "audio_proj_out") var audioOut: H3Projection

    /// The rotation frequencies. The diffusers export does not carry them — the
    /// reference builds them from `rope_freq_dim` and `rope_theta`, and this does
    /// the same arithmetic in double precision so the result is the tensor the
    /// task export stores, to the last bit of its fp32 rounding.
    let ropeInvFreq: MLXArray

    /// Where the transformer lives, and which file of it this is — the task
    /// preset decides which, so the URL is resolved when a read needs it.
    private let hub: HubApi
    let configuration: H3Configuration
    private var url: URL {
        get throws { try H3Loader.resolve(
            hub: hub, configuration: configuration, key: .transformerWeights) }
    }
    /// The layer stack. `layers[i]` is layer `i` while it is in memory and `nil`
    /// when it is not.
    ///
    /// The stack is 64.56 GB and is walked in full on each of the 20 denoise
    /// steps, so no machine this app targets holds it. ``runStack(_:)`` reads each
    /// layer as the step reaches it and gives it back on the way past, unless
    /// ``releasesLayersAfterUse`` says this machine can afford to keep what it
    /// has already read.
    private var layers: [H3OmniTransformerLayer?]
    /// Whether a step gives its layers back or keeps them for the next one.
    ///
    /// False at every tier this app has a preset for — see ``H3RuntimeProfile``.
    let releasesLayersAfterUse: Bool
    /// The dtype the layer stack runs in. H3 Base uses BF16 for its encoded
    /// conditions and denoising path.
    let computeDType: DType

    /// The declaration, with every parameter present but unread, and no layer
    /// built: the stack is read by ``runStack(_:)`` as a step reaches each layer,
    /// unless the machine's profile keeps it whole.
    ///
    /// The caller fills what is declared here from the checkpoint and then hands
    /// the model to the sampler — see
    /// ``H3Loader/loadOmniTransformer(hub:configuration:computeDType:report:)``.
    init(
        config: H3Configuration,
        hub: HubApi,
        configuration: H3Configuration,
        releasesLayersAfterUse: Bool,
        computeDType: DType = .bfloat16
    ) {
        self.config = config
        self.hub = hub
        self.configuration = configuration
        self.layers = Array(repeating: nil, count: config.numLayers)
        self.releasesLayersAfterUse = releasesLayersAfterUse
        self.computeDType = computeDType

        // The residual stream is the encoder's width, so the patch projections
        // lift a latent's patch features into it and the conditioning lifts the
        // text encoder's hidden state.
        self._conditionProj.wrappedValue = H3Projection(
            inputDimensions: config.textDim, outputDimensions: config.hiddenSize)
        self._videoPatchProj.wrappedValue = H3Projection(
            inputDimensions: config.videoLatentDim * config.patchVolume,
            outputDimensions: config.hiddenSize)
        self._audioPatchProj.wrappedValue = H3Projection(
            inputDimensions: config.audioLatentDim, outputDimensions: config.hiddenSize)
        self._tokenRefiner.wrappedValue = TokenRefiner(config: config)
        self._timeEmbedder.wrappedValue = TimeEmbedder(config: config)
        self._outputLayer.wrappedValue = H3OutputLayer(config: config)
        self._videoOut.wrappedValue = H3Projection(
            inputDimensions: config.hiddenSize,
            outputDimensions: config.videoLatentDim * config.patchVolume)
        self._audioOut.wrappedValue = H3Projection(
            inputDimensions: config.hiddenSize,
            outputDimensions: config.audioLatentDim)
        self.ropeInvFreq = MLXArray((0 ..< config.ropeInvFreqLen).map { i in
            Float(1.0 / pow(config.ropeTheta, Double(2 * i) / Double(2 * config.ropeInvFreqLen)))
        })
    }

    /// Precompute the exact prompt- and geometry-invariant DiT inputs for one
    /// render. Call once before the sampler loop and pass the result to every
    /// ``embed(videoLatent:audioLatent:textEmbeddings:sigmaVideo:geometry:textTags:condVideo:condAudio:renderState:)``
    /// in that loop.
    func prepareRender(
        textEmbeddings: MLXArray,
        layout: H3Sequence
    ) throws -> RenderState {
        precondition(layout.textTokens == textEmbeddings.dim(1))
        let textStates = conditionProj(textEmbeddings[0].asType(computeDType))
        let refined = tokenRefiner(textStates)
        let pos = MLXArray(layout.positionIds.map { Float($0) }, [layout.totalTokens, 3])
        let rope = H3RoPE.rotationTable(
            angles: H3RoPE.angles(positionIds: pos, invFreq: ropeInvFreq)
        ).asType(computeDType)
        return RenderState(layout: layout, textTokenCount: textEmbeddings.dim(1), textStates: textStates,
                           refined: refined, ropeTable: rope)
    }

    /// One denoise step's layers and everything they read from.
    ///
    /// The timestep embedding, modulation rows and RoPE table all come from sigma
    /// and the packed geometry, so they cannot outlive the step that built them.
    /// Handing the whole carrier to `run` means a caller walking the stack one
    /// layer at a time recomputes none of it.
    struct Step {
        /// The packed rows entering the stack, `[layout.totalTokens, hidden]`.
        let h: MLXArray
        fileprivate let tEmb: MLXArray
        fileprivate let index: ModulationIndex
        fileprivate let table: MLXArray
        fileprivate let layout: H3Sequence
        fileprivate let plan: TimestepPlan
        fileprivate let geometry: H3LatentGeometry
    }

    /// Opens one denoise step: everything before the layer stack.
    ///
    /// Conditions the prompt through the refiner, patchifies the latents, and
    /// builds the timestep embedding and RoPE table every layer reads.
    ///
    /// - Parameters:
    ///   - videoLatent: `[1,24,T,H,W]`
    ///   - audioLatent: `[1,32,2,audioT]`
    ///   - textEmbeddings: `[1, textLen, textDim]` — output of the H3 Encoder
    ///   - renderState: carries the segment table and `[S,3]` position ids
    func embed(videoLatent: MLXArray, audioLatent: MLXArray,
                       textEmbeddings: MLXArray, sigmaVideo: Double,
                       geometry: H3LatentGeometry, textTags: [Int]? = nil,
                       condVideo: MLXArray? = nil,
                       condAudio: MLXArray? = nil,
                       renderState: RenderState? = nil) throws -> Step {
        guard let renderState else {
            throw H3EvaluatorError.invalidRequest(
                rule: "missing H3 render layout",
                detail: "embed was called before the task-specific packed sequence was prepared",
                remedy: "prepare the FL2VA or Ref2VA render state before sampling.")
        }
        let layout = renderState.layout
        let plan = TimestepPlan(sigmaVideo: sigmaVideo, segments: layout.segments)
        let index = ModulationIndex(layout: layout, plan: plan, textTags: textTags)

        // Text conditioning is projected in the transformer's working dtype.
        precondition(renderState.textTokenCount == textEmbeddings.dim(1),
                     "RenderState does not match this render's text length")
        let refined = renderState.refined
        // media path — patch projections are part of the fp32 island, so the
        // rows go in as fp32 and the result is cast down to the compute dtype.
        let videoRows = H3Packing.patchifyVideo(videoLatent.asType(.float32),
                                                patch: config.patchSize)
        let audioRows = H3Packing.packAudio(audioLatent.asType(.float32))

        var allVideoRows = [MLXArray]()
        var condVideoOffset = 0
        for s in layout.segments {
            if s.kind == .visualCondition {
                // The layout says there are conditioning rows and the caller did
                // not supply them. Reachable from ordinary wrong input — a
                // keyframe declared but never encoded — so it refuses rather
                // than trapping.
                guard let condVideo = condVideo else {
                    throw H3EvaluatorError.invalidRequest(
                        rule: "missing conditioning rows",
                        detail: "the packed layout declares a \(s.kind.rawValue) segment of "
                              + "\(s.count) row(s), and no conditioning video was supplied",
                        remedy: "encode every declared condition before sampling; the layout "
                              + "and the rows are built from the same latents for this reason.")
                }
                let slice = condVideo[condVideoOffset ..< (condVideoOffset + s.count)]
                allVideoRows.append(slice)
                condVideoOffset += s.count
            } else if s.kind == .video {
                allVideoRows.append(videoRows)
            }
        }
        let videoEmbed = videoPatchProj(concatenated(allVideoRows, axis: 0))

        var allAudioRows = [MLXArray]()
        var condAudioOffset = 0
        for segment in layout.segments where segment.kind.isAudioStream {
            if segment.kind == .audioCondition {
                guard let condAudio else {
                    throw H3EvaluatorError.invalidRequest(
                        rule: "missing audio reference rows",
                        detail: "the Ref2VA layout declares \(segment.count) audio condition row(s)",
                        remedy: "encode every audio-bearing reference before sampling.")
                }
                let slice = condAudio[condAudioOffset ..< (condAudioOffset + segment.count)]
                allAudioRows.append(slice)
                condAudioOffset += segment.count
            } else {
                allAudioRows.append(audioRows)
            }
        }
        let audioEmbed = audioPatchProj(concatenated(allAudioRows, axis: 0))

        // pack segments in the layout's segment table order
        let dtype = computeDType
        var hSegments = [MLXArray]()
        var vEmbedOffset = 0
        var aEmbedOffset = 0

        for s in layout.segments {
            switch s.kind {
            case .text:
                hSegments.append(refined.asType(dtype))
            case .visualCondition, .video:
                let slice = videoEmbed[vEmbedOffset ..< (vEmbedOffset + s.count)].asType(dtype)
                hSegments.append(slice)
                vEmbedOffset += s.count
            case .audioCondition, .audio:
                let slice = audioEmbed[aEmbedOffset ..< (aEmbedOffset + s.count)].asType(dtype)
                hSegments.append(slice)
                aEmbedOffset += s.count
            }
        }
        let h = concatenated(hSegments, axis: 0)

        precondition(h.dim(0) == layout.totalTokens,
                     "packed \(h.dim(0)) rows, layout says \(layout.totalTokens)")

        let tEmb = timeEmbedder(MLXArray(plan.values)).asType(dtype)

        return Step(h: h, tEmb: tEmb, index: index, table: renderState.ropeTable,
                    layout: layout, plan: plan, geometry: geometry)
    }

    /// Runs one layer of the stack on the step's hidden state.
    ///
    /// This is the only place a layer is invoked, so there is no second
    /// arithmetic path for a layer to disagree with itself about.
    private func run(_ layer: H3OmniTransformerLayer, _ step: Step, h: MLXArray) -> MLXArray {
        layer(h, tEmb: step.tEmb, index: step.index, ropeTable: step.table)
    }

    /// Runs the whole stack for one denoise step, reading each layer as the step
    /// reaches it.
    ///
    /// A layer already in memory costs nothing; one that is not reads its
    /// checkpoint file. Whether the step keeps what it read is the machine's
    /// decision, not a second code path: see ``releasesLayersAfterUse``.
    func runStack(_ step: Step) throws -> (video: MLXArray, audio: MLXArray) {
        var h = step.h
        for index in 0 ..< config.numLayers {
            if layers[index] == nil {
                layers[index] = try H3Loader.loadTransformerLayer(
                    index: index, url: try url, config: config)
            }
            h = run(layers[index]!, step, h: h)
            if releasesLayersAfterUse {
                // The next step starts at layer 0 again, and a layer beyond this
                // one is 1.29 GB nothing is going to ask for in between.
                layers[index] = nil
            }
        }
        return finish(h, step)
    }

    /// Closes one denoise step: the final layer, then the latent-shaped velocity
    /// for both streams.
    ///
    /// Returns exactly what the reference does. Two sign conventions are baked in
    /// and neither is cosmetic: **both streams are negated**, and audio is
    /// additionally scaled by `d(sigma_a)/d(sigma_v)` so that the single flat ODE
    /// the sampler integrates is each stream's true ODE on its own shifted
    /// schedule.
    func finish(_ h: MLXArray, _ step: Step) -> (video: MLXArray, audio: MLXArray) {
        let layout = step.layout
        let plan = step.plan

        // The final layer's AdaLN has one modality, so these rows are timestep
        // rows — not the `row * 3 + tag` a layer uses.
        let videoSeg = ModSegment(start: layout.videoRange.lowerBound,
                                  stop: layout.videoRange.upperBound, row: plan.row(for: .video))
        let audioSeg = ModSegment(start: layout.audioRange.lowerBound,
                                  stop: layout.audioRange.upperBound, row: plan.row(for: .audio))
        let m = outputLayer.adaln(step.tEmb)
        precondition(m.count == 2, "the output AdaLN must expand to 2, got \(m.count)")
        let shift = m[0], scale = m[1]

        /// The heads are the export's fp32 island, so the whole head runs there
        /// rather than in the block's working dtype.
        func head(_ seg: ModSegment, _ out: H3Projection) -> MLXArray {
            let slice = h.ndim == 3 ? h[0..., seg.start ..< seg.stop] : h[seg.start ..< seg.stop]
            let sc = scale[seg.row].expandedDimensions(axis: 0)
            let sh = shift[seg.row].expandedDimensions(axis: 0)
            let x = (outputLayer.norm(slice) * (1.0 + sc) + sh).asType(.float32)
            return matmul(x, out.weight.asType(.float32).T) + out.bias.asType(.float32)
        }
        let (v, a) = (head(videoSeg, videoOut), head(audioSeg, audioOut))

        let geometry = step.geometry
        let video = H3Packing.unpatchifyVideo(v, t: geometry.latentT,
                                              h: geometry.latentH / config.patchSize[1],
                                              w: geometry.latentW / config.patchSize[2],
                                              channels: config.videoLatentDim,
                                              patch: config.patchSize)
        let audio = H3Packing.unpackAudio(a)
        return (-video, MLXArray(-plan.audioSlope) * audio)
    }

}


/// One layer of the Omni Transformer's stack.
///
/// The stack is 50 of these. Each is 1.29 GB, so which ones are in memory at a
/// given moment is the whole memory question, and a layer is therefore the unit
/// a caller loads, runs and lets go of.
///
/// A `Module` whose parts are declared one level per level of the checkpoint's
/// names, so ``H3Loader/loadTransformerLayer(index:url:config:)`` builds one by
/// filling this declaration from the tensors whose names start `blocks.<index>.`:
/// the names and the structure are the same statement. That matters here — a
/// mis-wiring would not fail to load, it would produce a plausible-looking wrong
/// video.
final class H3OmniTransformerLayer: Module {
    @ModuleInfo var norm1: H3RMSNorm
    @ModuleInfo var norm2: H3RMSNorm
    @ModuleInfo var attn: AttentionLayer
    @ModuleInfo(key: "ff") var ff: H3FeedForward
    @ModuleInfo(key: "adaln_proj") var adaln: AdalnProj

    /// The declaration, with every parameter present but unread.
    ///
    /// `adaln_proj` expands to 6 because a block modulates three streams — video,
    /// text and audio — with a shift and a scale each.
    init(config: H3Configuration, fp32Attention: Bool = false) {
        self._norm1.wrappedValue = H3RMSNorm(dimensions: config.hiddenSize, eps: config.normEps)
        self._norm2.wrappedValue = H3RMSNorm(dimensions: config.hiddenSize, eps: config.normEps)
        self._attn.wrappedValue = AttentionLayer(config: config, fp32Attention: fp32Attention)
        self._ff.wrappedValue = H3FeedForward(config: config)
        self._adaln.wrappedValue = AdalnProj(
            expand: 6, modalities: 3, hidden: config.hiddenSize,
            inputDim: config.timeEmbedDim)
    }

    func callAsFunction(_ x: MLXArray, tEmb: MLXArray, index: ModulationIndex,
                               ropeTable: MLXArray?) -> MLXArray {
        let m = adaln(tEmb)
        precondition(m.count == 6, "H3OmniTransformerLayer AdaLN must expand to 6, got \(m.count)")

        func norm(_ v: MLXArray, _ n: H3RMSNorm, _ shift: MLXArray,
                  _ scale: MLXArray) -> MLXArray {
            modScaleShift(n(v), shift: shift, scale: scale, index: index)
        }
        func gated(_ v: MLXArray, _ gate: MLXArray, _ other: MLXArray) -> MLXArray {
            modGate(v, gate: gate, other: other, index: index)
        }

        let h1 = norm(x, norm1, m[0], m[1])
        let x1 = gated(x, m[2], attn(h1, ropeTable: ropeTable))
        let h2 = norm(x1, norm2, m[3], m[4])
        return gated(x1, m[5], ff(h2))
    }
}

/// Two pre-norm blocks with plain residuals, then a final RMSNorm. No AdaLN,
/// no RoPE — the refiner sees text only.
final class TokenRefiner: Module {
    /// One of the two: the same attention and MLP a DiT block has, without the
    /// modulation.
    final class Block: Module {
        @ModuleInfo var norm1: H3RMSNorm
        @ModuleInfo var norm2: H3RMSNorm
        @ModuleInfo var attn: AttentionLayer
        @ModuleInfo(key: "ff") var ff: H3FeedForward

        init(config: H3Configuration) {
            self._norm1.wrappedValue = H3RMSNorm(
                dimensions: config.hiddenSize, eps: config.normEps)
            self._norm2.wrappedValue = H3RMSNorm(
                dimensions: config.hiddenSize, eps: config.normEps)
            self._attn.wrappedValue = AttentionLayer(config: config)
            self._ff.wrappedValue = H3FeedForward(config: config)
        }

        func callAsFunction(_ x: MLXArray) -> MLXArray {
            let a = attn(norm1(x), ropeTable: nil) + x
            return ff(norm2(a)) + a
        }
    }

    @ModuleInfo(key: "refiner_blocks") var blocks: [Block]
    @ModuleInfo(key: "final_norm") var finalNorm: H3RMSNorm

    init(config: H3Configuration) {
        self._blocks.wrappedValue = (0 ..< config.tokenRefinerLayers).map { _ in
            Block(config: config)
        }
        self._finalNorm.wrappedValue = H3RMSNorm(
            dimensions: config.hiddenSize, eps: config.finalNormEps)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = x
        for b in blocks { h = b(h) }
        return finalNorm(h)
    }
}

/// `norm_out` — the output norm and the AdaLN that modulates it.
///
/// The same shape a block's AdaLN has, with one modality and two expansions
/// instead of three and six, so its rows are timestep rows rather than
/// `timestepRow * 3 + tag`.
final class H3OutputLayer: Module {
    @ModuleInfo var norm: H3RMSNorm
    @ModuleInfo(key: "linear") var adaln: H3Projection

    init(config: H3Configuration) {
        self._norm.wrappedValue = H3RMSNorm(
            dimensions: config.hiddenSize, eps: config.finalNormEps)
        self._adaln.wrappedValue = H3Projection(
            inputDimensions: config.timeEmbedDim,
            outputDimensions: config.finalAdalnOutFeatures)
    }
}


struct ModSegment: Sendable, Equatable {
    let start: Int
    let stop: Int
    let row: Int
    init(start: Int, stop: Int, row: Int) {
        self.start = start
        self.stop = stop
        self.row = row
    }
}

struct ModulationIndex {
    /// `[S]` — AdaLN row for each token in the packed sequence.
    let rows: MLXArray
    let tokenCount: Int

    init(segments: [ModSegment], tokenCount: Int) {
        var r = [Int32](repeating: -1, count: tokenCount)
        for s in segments {
            precondition(s.start >= 0 && s.stop <= tokenCount && s.start <= s.stop,
                         "segment \(s) outside 0..<\(tokenCount)")
            for i in s.start ..< s.stop { r[i] = Int32(s.row) }
        }
        precondition(!r.contains(-1), "mod segments must cover the packed sequence contiguously")
        self.rows = MLXArray(r)
        self.tokenCount = tokenCount
    }

    /// Rows given directly, one per token.
    init(rows: MLXArray) {
        self.rows = rows
        self.tokenCount = rows.dim(0)
    }

    /// Rows for a layout under one timestep plan.
    ///
    /// `textTags` is the per-token modality for a text span containing visual
    /// tokens. A plain text prompt can omit it because every text token uses the
    /// text modality.
    init(layout: H3Sequence, plan: TimestepPlan, textTags: [Int]? = nil) {
        var segs: [ModSegment] = []
        for s in layout.segments {
            let base = plan.row(for: s.kind) * 3
            if s.kind == .text, let tags = textTags {
                precondition(tags.count == s.count,
                             "textTags has \(tags.count) entries for a \(s.count)-token text span")
                var runStart = 0
                for i in 1 ... tags.count where i == tags.count || tags[i] != tags[runStart] {
                    segs.append(ModSegment(start: s.start + runStart, stop: s.start + i,
                                           row: base + tags[runStart]))
                    runStart = i
                }
            } else {
                segs.append(ModSegment(start: s.start, stop: s.stop,
                                       row: base + s.kind.modality.rawValue))
            }
        }
        self.init(segments: segs, tokenCount: layout.totalTokens)
    }

    /// `[rows, hidden]` -> `[S, hidden]`, one row per token.
    func gather(_ table: MLXArray) -> MLXArray { table[rows] }
}

/// `h * (1 + scale) + shift`, per token.
func modScaleShift(_ h: MLXArray, shift: MLXArray, scale: MLXArray,
                          index: ModulationIndex) -> MLXArray {
    h * (1.0 + index.gather(scale)) + index.gather(shift)
}

/// `x + other * gate`, per token.
func modGate(_ x: MLXArray, gate: MLXArray, other: MLXArray,
                    index: ModulationIndex) -> MLXArray {
    x + other * index.gather(gate)
}

/// RMSNorm over the last axis: `x * rsqrt(mean(x^2) + eps) * weight`.
///
/// Computed in fp32 and cast back to the input dtype.
///
/// A `Module` so the layer stacks can declare one and let `update(parameters:)`
/// fill it by path. The tensor-taking initializer stays for callers that already
/// hold the weight; `dimensions` allocates the shape that lookup replaces, which
/// is what a declaration needs, since a parameter is filled by being found in the
/// module's own structure.
final class H3RMSNorm: Module {
    @ParameterInfo var weight: MLXArray
    let eps: Float
    init(weight: MLXArray, eps: Float) {
        self.eps = eps
        self._weight.wrappedValue = weight
    }

    init(dimensions: Int, eps: Float) {
        self.eps = eps
        self._weight.wrappedValue = MLXArray.ones([dimensions])
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let f = x.asType(.float32)
        let n = f * rsqrt(mean(f * f, axis: -1, keepDims: true) + eps)
        return (n * weight.asType(.float32)).asType(x.dtype)
    }
}


/// AdaLN projection: `chunk(linear(silu(t_emb)), expand)`.
///
/// `t_emb` is `[M, tDim]` for M distinct timesteps; the output is `expand`
/// tensors of `[M * modalities, hidden]`. The reshape interleaves modalities
/// **within** each timestep, which is what makes the row index
/// `timestepRow * modalities + modalityTag`.
final class AdalnProj: Module {
    @ModuleInfo(key: "linear") var linear: H3Projection   // [expand * hidden * modalities, tDim]
    let expand: Int
    let modalities: Int
    let hidden: Int
    let applySiLU: Bool
    /// Compute the projection in fp32 and cast the result back to the model's
    /// working dtype.
    ///
    /// The AdaLN matrices are the largest in a layer and the modulation they
    /// produce is small, so the extra precision is nearly free.
    let computeFP32: Bool

    init(expand: Int, modalities: Int, hidden: Int, inputDim: Int,
         applySiLU: Bool = true, computeFP32: Bool = true) {
        self.expand = expand
        self.modalities = modalities
        self.hidden = hidden
        self.applySiLU = applySiLU
        self.computeFP32 = computeFP32
        self._linear.wrappedValue = H3Projection(
            inputDimensions: inputDim, outputDimensions: expand * hidden * modalities)
    }

    /// Returns `expand` tensors of `[M * modalities, hidden]`, in the weight's
    /// dtype whatever the internal precision.
    func callAsFunction(_ tEmb: MLXArray) -> [MLXArray] {
        let out = linear.weight.dtype
        let dt: DType = computeFP32 ? .float32 : out
        let input = applySiLU ? silu(tEmb.asType(dt)) : tEmb.asType(dt)
        let weight = dt == .float32 ? linear.weight.asType(dt) : linear.weight
        var x = matmul(input, weight.T)
        x = x + linear.bias.asType(dt)
        x = x.reshaped([x.dim(0) * modalities, expand * hidden]).asType(out)
        return (0 ..< expand).map { x[0..., ($0 * hidden) ..< (($0 + 1) * hidden)] }
    }
}

/// Split-half rotary embedding.
///
/// The rotation table is `[1, S, 1, rot/2, 2, 2]` holding `[[c, -s], [s, c]]`,
/// and pairs are `(i, i + rot/2)` — **split-half, not interleaved**. Choosing
/// interleaved is the single most common RoPE porting error and produces output
/// that looks structured but is wrong.
///
/// Only the first `rot` channels rotate; the tail passes through untouched.
enum SplitHalfRoPE {
    /// `x` is `[S, heads, headDim]` or `[B, S, heads, headDim]`; `table` is the reference's rotation table.
    static func apply(_ x: MLXArray, table: MLXArray) -> MLXArray {
        let half = table.dim(-3)
        let rot = half * 2
        let headDim = x.dim(-1)
        precondition(rot <= headDim, "rot \(rot) exceeds headDim \(headDim)")

        // [1,S,1,half,2,2] -> [S,1,half] so it broadcasts over heads.
        let t = table.reshaped([table.dim(1), half, 2, 2])
        let c = t[0..., 0..., 0, 0].expandedDimensions(axis: 1)
        let negS = t[0..., 0..., 0, 1].expandedDimensions(axis: 1)
        let s = t[0..., 0..., 1, 0].expandedDimensions(axis: 1)
        let c2 = t[0..., 0..., 1, 1].expandedDimensions(axis: 1)

        let parts = x.split(indices: [half, rot], axis: -1)
        let a = parts[0]
        let b = parts[1]
        let ra = c * a + negS * b
        let rb = s * a + c2 * b
        if rot == headDim { return concatenated([ra, rb], axis: -1) }
        return concatenated([ra, rb, parts[2]], axis: -1)
    }
}

/// Attention over the packed sequence.
///
/// Named `AttentionLayer` rather than `H3Attention` because `H3Attention` is the
/// module that owns the backend protocol, and a type that shadows its own
/// module's name reads as a mistake even when it compiles.
final class AttentionLayer: Module {
    /// Separate projections, and none of them carries a bias — which is why the
    /// export has a `weight` for each and no `bias`.
    @ModuleInfo(key: "to_q") var toQ: Linear
    @ModuleInfo(key: "to_k") var toK: Linear
    @ModuleInfo(key: "to_v") var toV: Linear
    @ModuleInfo(key: "to_out") var toOut: H3Projection   // `to_out.0`, a one-element list
    @ModuleInfo(key: "q_norm") var qNorm: H3RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: H3RMSNorm
    let heads: Int
    let headDim: Int
    /// Run the attention operation in fp32 while the rest of the block stays in
    /// the model's working dtype.
    let fp32Attention: Bool

    init(config: H3Configuration, fp32Attention: Bool = false) {
        // Attention widens past the residual: 56 heads of 128 is 7168 while the
        // block's hidden size is 5376, and the output projection brings it back.
        let inner = config.numHeads * config.headDim
        self.heads = config.numHeads
        self.headDim = config.headDim
        self.fp32Attention = fp32Attention
        self._toQ.wrappedValue = Linear(config.hiddenSize, inner, bias: false)
        self._toK.wrappedValue = Linear(config.hiddenSize, inner, bias: false)
        self._toV.wrappedValue = Linear(config.hiddenSize, inner, bias: false)
        self._toOut.wrappedValue = H3Projection(
            inputDimensions: inner, outputDimensions: config.hiddenSize)
        self._qNorm.wrappedValue = H3RMSNorm(dimensions: config.headDim, eps: config.qkNormEps)
        self._kNorm.wrappedValue = H3RMSNorm(dimensions: config.headDim, eps: config.qkNormEps)
    }

    /// Scaled dot-product attention over `[S, heads, headDim]` or
    /// `[B, S, heads, headDim]` inputs. A backend may handle the unbatched H3
    /// path; batched text refinement uses the dense MLX operation.
    static func sdpa(q: MLXArray, k: MLXArray, v: MLXArray,
                            headDim: Int, fp32: Bool = false) -> MLXArray {
        let at: DType = fp32 ? .float32 : q.dtype
        let hasBatch = q.ndim == 4
        let qh = hasBatch ? q.transposed(0, 2, 1, 3).asType(at) : q.transposed(1, 0, 2).expandedDimensions(axis: 0).asType(at)
        let kh = hasBatch ? k.transposed(0, 2, 1, 3).asType(at) : k.transposed(1, 0, 2).expandedDimensions(axis: 0).asType(at)
        let vh = hasBatch ? v.transposed(0, 2, 1, 3).asType(at) : v.transposed(1, 0, 2).expandedDimensions(axis: 0).asType(at)

        let scale = 1.0 / Float(headDim).squareRoot()

        let out = MLXFast.scaledDotProductAttention(
            queries: qh, keys: kh, values: vh, scale: scale, mask: nil)

        if hasBatch {
            return out.transposed(0, 2, 1, 3).asType(q.dtype).reshaped([q.dim(0), q.dim(1), q.dim(2) * headDim])
        } else {
            return out.squeezed(axis: 0).transposed(1, 0, 2).asType(q.dtype).reshaped([q.dim(0), q.dim(1) * headDim])
        }
    }

    /// `x` is `[S, hidden]` or `[B, S, hidden]`.
    ///
    func callAsFunction(_ x: MLXArray, ropeTable: MLXArray?) -> MLXArray {
        let targetShape = x.shape.dropLast() + [heads, headDim]
        var q = toQ(x).reshaped(targetShape)
        var k = toK(x).reshaped(targetShape)
        let v = toV(x).reshaped(targetShape)

        // RMSNorm is applied per head BEFORE rope, as the fused kernel does.
        q = qNorm(q)
        k = kNorm(k)
        if let ropeTable {
            q = SplitHalfRoPE.apply(q, table: ropeTable)
            k = SplitHalfRoPE.apply(k, table: ropeTable)
        }

        let merged = Self.sdpa(
            q: q,
            k: k,
            v: v,
            headDim: headDim,
            fp32: fp32Attention)
        return toOut(merged)
    }
}

/// `fc2(silu(gate) * up)` where `fc1` emits `2 * ffn` and gate is the first
/// half of the split.
final class H3FeedForward: Module {
    /// `w1` emits twice the feed-forward width and the first half is the gate.
    @ModuleInfo var w1: Linear   // [2 * ffn, hidden]
    @ModuleInfo var w2: Linear   // [hidden, ffn]

    init(config: H3Configuration) {
        self._w1.wrappedValue = Linear(config.hiddenSize, 2 * config.ffnHidden, bias: false)
        self._w2.wrappedValue = Linear(config.ffnHidden, config.hiddenSize, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let parts = w1(x).split(parts: 2, axis: -1)
        return w2(silu(parts[0]) * parts[1])
    }
}

/// A `weight` and a `bias` under one name: the shape most of this checkpoint's
/// affine maps take, in the DiT and in the Visual VAE both.
///
/// Held rather than given to MLX as a `Linear` because the callers choose their
/// own arithmetic dtype per call — the AdaLN projection projects in fp32 and
/// reshapes its output into `expand` tensors, the final layer's heads are the
/// export's fp32 island, and the VAE's `post_quant_conv` flattens a convolution's
/// weight before using it. A `Linear` would decide all three for them.
final class H3Projection: Module {
    @ParameterInfo var weight: MLXArray
    @ParameterInfo var bias: MLXArray

    init(weight: MLXArray, bias: MLXArray) {
        self._weight.wrappedValue = weight
        self._bias.wrappedValue = bias
    }

    /// The declaration's placeholder — the shapes `update` replaces.
    init(inputDimensions: Int, outputDimensions: Int) {
        self._weight.wrappedValue = MLXArray.zeros([outputDimensions, inputDimensions])
        self._bias.wrappedValue = MLXArray.zeros([outputDimensions])
    }

    /// The declaration's placeholder where the weight is not `[out, in]`.
    ///
    /// A checkpoint that stores its convolutions PyTorch-style keeps the kernel
    /// axes: a 1x1x1 is `[out, in, 1, 1, 1]`, and the caller flattens it where it
    /// is used because the stride equals the kernel.
    init(weightShape: [Int], biasShape: [Int]) {
        self._weight.wrappedValue = MLXArray.zeros(weightShape)
        self._bias.wrappedValue = MLXArray.zeros(biasShape)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        matmul(x, weight.T) + bias
    }
}

/// Packing helpers. These decide the ROW ORDER of the packed sequence, so an
/// error here misaligns every downstream tap while keeping all the shapes
/// correct — the most expensive kind of bug to find late.
enum H3Packing {
    /// `[B,C,T,H,W] -> [B*t*h*w, C*pt*ph*pw]`, rows ordered t-major then h then w.
    ///
    /// Reference: `einsum("nctrhpwq->nthwcrpq")`. Feature order within a row is
    /// `(c, pt, ph, pw)` — channel outermost, patch offsets innermost.
    static func patchifyVideo(_ latent: MLXArray, patch: [Int] = [1, 2, 2]) -> MLXArray {
        let b = latent.dim(0), c = latent.dim(1)
        let (pt, ph, pw) = (patch[0], patch[1], patch[2])
        let t = latent.dim(2) / pt, h = latent.dim(3) / ph, w = latent.dim(4) / pw
        // n c (t pt) (h ph) (w pw) -> n t h w c pt ph pw
        return latent.reshaped([b, c, t, pt, h, ph, w, pw])
                     .transposed(0, 2, 4, 6, 1, 3, 5, 7)
                     .reshaped([b * t * h * w, c * pt * ph * pw])
    }

    static func unpatchifyVideo(_ rows: MLXArray, t: Int, h: Int, w: Int,
                                       channels: Int = 24, patch: [Int] = [1, 2, 2]) -> MLXArray {
        let (pt, ph, pw) = (patch[0], patch[1], patch[2])
        return rows.reshaped([-1, t, h, w, channels, pt, ph, pw])
                   .transposed(0, 4, 1, 5, 2, 6, 3, 7)
                   .reshaped([-1, channels, t * pt, h * ph, w * pw])
    }

    /// `[B,32,2,T] -> [2*T, 32]`, **channel-major**: ch0 t0..T-1 then ch1 t0..T-1.
    /// Reference: `latent[0].permute(1,2,0).reshape(ch*t, c)`.
    static func packAudio(_ latent: MLXArray) -> MLXArray {
        let c = latent.dim(1), ch = latent.dim(2), t = latent.dim(3)
        return latent[0].transposed(1, 2, 0).reshaped([ch * t, c])
    }

    static func unpackAudio(_ rows: MLXArray, channels: Int = 2) -> MLXArray {
        let t = rows.dim(0) / channels
        return rows.reshaped([channels, t, rows.dim(-1)])
                   .transposed(2, 0, 1)
                   .expandedDimensions(axis: 0)
    }
}

/// RoPE frequency construction.
///
///     per_axis = pos[:, :, None] * inv_freq        [S, 3, 16]
///     half     = cat(t, h, w)                      [S, 48]
///     angles   = cat(half, half)                   [S, 96]
///
/// The duplicated halves are why `rope_rotation_table` only reads the first
/// half — and why `rot` is 96 while `headDim` is 128, leaving 32 channels
/// unrotated.
enum H3RoPE {
    /// `positionIds` is `[S, 3]` (t, h, w). Returns `[S, 96]` angles.
    static func angles(positionIds: MLXArray, invFreq: MLXArray) -> MLXArray {
        let pos = positionIds.asType(.float32)
        let inv = invFreq.asType(.float32).reshaped([1, 1, -1])
        let perAxis = pos.expandedDimensions(axis: -1) * inv          // [S,3,16]
        let s = perAxis.dim(0)
        let half = perAxis.reshaped([s, -1])                          // [S,48] = t|h|w
        return concatenated([half, half], axis: -1)                   // [S,96]
    }

    /// `[S, rot] angles -> [1, S, 1, rot/2, 2, 2]` holding `[[c, -s], [s, c]]`.
    static func rotationTable(angles: MLXArray) -> MLXArray {
        let s = angles.dim(0)
        let half = angles.dim(-1) / 2
        let ang = angles[0..., 0 ..< half]
        let c = cos(ang), sn = sin(ang)
        return stacked([c, -sn, sn, c], axis: -1).reshaped([1, s, 1, half, 2, 2])
    }
}

/// Sinusoidal-style timestep embedding: `proj_out(silu(proj_in(t)))`.
/// Only used when the model export has no `adaln_t_table`; H3 Base does not, which
/// the inventory confirms by deriving `timestepInputDim` from `proj_in`.
final class TimeEmbedder: Module {
    @ModuleInfo(key: "linear_1") var projIn: H3Projection
    @ModuleInfo(key: "linear_2") var projOut: H3Projection
    let inputDim: Int

    init(config: H3Configuration) {
        self.inputDim = config.timestepInputDim
        self._projIn.wrappedValue = H3Projection(
            inputDimensions: config.timestepInputDim,
            outputDimensions: config.timeEmbedHidden)
        self._projOut.wrappedValue = H3Projection(
            inputDimensions: config.timeEmbedHidden,
            outputDimensions: config.timeEmbedDim)
    }

    /// `t` is `[M]` timestep values in [0, 1].
    func callAsFunction(_ t: MLXArray) -> MLXArray {
        projOut(silu(projIn(sinusoid(t))))
    }

    /// Standard half-cos/half-sin frequency embedding of width `inputDim`,
    /// **cos before sin**.
    ///
    /// The association is the reference's, not the algebraically tidier one:
    /// `exp(-log(10000) * i / half)` multiplies before dividing. Folding the
    /// constant first — `i * (-log(10000)/half)` — is the same number in real
    /// arithmetic and a different one in fp32, and it showed up as a 2.5e-06
    /// discrepancy on a tap that is otherwise bit-exact.
    func sinusoid(_ t: MLXArray) -> MLXArray {
        let half = inputDim / 2
        let scale = Float(-Foundation.log(10000.0))
        let freqs = exp(MLXArray(0 ..< half).asType(.float32) * scale / Float(half))
        let a = t.asType(.float32).expandedDimensions(axis: -1) * freqs.reshaped([1, -1])
        return concatenated([cos(a), sin(a)], axis: -1)
    }
}
