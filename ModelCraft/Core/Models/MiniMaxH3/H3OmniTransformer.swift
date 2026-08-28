// SPDX-License-Identifier: Apache-2.0

import Foundation
import Hub
import MLX
import MLXFast
import MLXNN

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Kammerich


/// Optional context reserved for future attention implementations.
struct AttentionContext: Sendable {
    let blockIndex: Int
    let blockCount: Int
    let scheduleProgress: Double
    let sequenceLength: Int
    let videoSpan: Range<Int>?
}

/// Attention implementation used by H3 Base.
///
/// H3 currently uses MLX's dense SDPA. Keeping this small seam means a Metal
/// attention kernel can be added later without making the Evaluator aware of it.
protocol H3AttentionBackend: Sendable {
    init()
    static var identifier: String { get }

    func attend(
        queries: MLXArray,
        keys: MLXArray,
        values: MLXArray,
        scale: Float,
        mask: MLXArray?,
        context: AttentionContext?
    ) -> MLXArray
}

struct SDPABackend: H3AttentionBackend {
    static let identifier = "sdpa"

    init() {}

    func attend(
        queries: MLXArray,
        keys: MLXArray,
        values: MLXArray,
        scale: Float,
        mask: MLXArray?,
        context: AttentionContext?
    ) -> MLXArray {
        MLXFast.scaledDotProductAttention(
            queries: queries.expandedDimensions(axis: 0),
            keys: keys.expandedDimensions(axis: 0),
            values: values.expandedDimensions(axis: 0),
            scale: scale,
            mask: mask)
            .squeezed(axis: 0)
    }
}

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Kammerich



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
struct H3RMSNorm {
    let weight: MLXArray
    let eps: Float
    init(weight: MLXArray, eps: Float) {
        self.weight = weight
        self.eps = eps
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let f = x.asType(.float32)
        let n = f * rsqrt(mean(f * f, axis: -1, keepDims: true) + eps)
        return (n * weight.asType(.float32)).asType(x.dtype)
    }
}

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Kammerich


/// AdaLN projection: `chunk(linear(silu(t_emb)), expand)`.
///
/// `t_emb` is `[M, tDim]` for M distinct timesteps; the output is `expand`
/// tensors of `[M * modalities, hidden]`. The reshape interleaves modalities
/// **within** each timestep, which is what makes the row index
/// `timestepRow * modalities + modalityTag`.
struct AdalnProj {
    let weight: MLXArray      // [expand * hidden * modalities, tDim]
    let bias: MLXArray?
    let expand: Int
    let modalities: Int
    let hidden: Int
    let applySiLU: Bool
    /// Compute the projection in fp32 when requested and cast the result back to
    /// the model's working dtype.
    let computeFP32: Bool
    /// Optional persistent fp32 copy for callers that prefer stable residency
    /// over repeated conversion of the AdaLN matrices.
    let residentFP32Weight: MLXArray?

    init(weight: MLXArray, bias: MLXArray?, expand: Int, modalities: Int,
                hidden: Int, applySiLU: Bool = true, computeFP32: Bool = true,
                keepFP32Resident: Bool = false) {
        self.weight = weight
        self.bias = bias
        self.expand = expand
        self.modalities = modalities
        self.hidden = hidden
        self.applySiLU = applySiLU
        self.computeFP32 = computeFP32
        self.residentFP32Weight = keepFP32Resident && computeFP32 ? weight.asType(.float32) : nil
    }

    /// Returns `expand` tensors of `[M * modalities, hidden]`, in the weight's
    /// dtype whatever the internal precision.
    func callAsFunction(_ tEmb: MLXArray) -> [MLXArray] {
        let out = weight.dtype
        let dt: DType = computeFP32 ? .float32 : out
        let input = applySiLU ? silu(tEmb.asType(dt)) : tEmb.asType(dt)
        let projectionWeight = dt == .float32 ? (residentFP32Weight ?? weight.asType(dt)) : weight
        var x = matmul(input, projectionWeight.T)
        if let bias { x = x + bias.asType(dt) }
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
struct AttentionLayer {
    let qkvWeight: MLXArray     // [3 * inner, hidden], no bias
    let outWeight: MLXArray     // [hidden, inner], no bias
    let qNorm: H3RMSNorm
    let kNorm: H3RMSNorm
    let heads: Int
    let headDim: Int
    /// Run the attention operation in fp32 while the rest of the block stays in
    /// the model's working dtype.
    let fp32Attention: Bool
    /// The backend is resolved once at model build and held for every call.
    let backend: any H3AttentionBackend

    init(qkvWeight: MLXArray, outWeight: MLXArray,
                qNormWeight: MLXArray, kNormWeight: MLXArray,
                heads: Int, headDim: Int, eps: Float, fp32Attention: Bool = false,
                backend: any H3AttentionBackend = SDPABackend()) {
        self.qkvWeight = qkvWeight
        self.outWeight = outWeight
        self.qNorm = H3RMSNorm(weight: qNormWeight, eps: eps)
        self.kNorm = H3RMSNorm(weight: kNormWeight, eps: eps)
        self.heads = heads
        self.headDim = headDim
        self.fp32Attention = fp32Attention
        self.backend = backend
    }

    /// Scaled dot-product attention over `[S, heads, headDim]` or
    /// `[B, S, heads, headDim]` inputs. A backend may handle the unbatched H3
    /// path; batched text refinement uses the dense MLX operation.
    static func sdpa(q: MLXArray, k: MLXArray, v: MLXArray,
                            headDim: Int, fp32: Bool = false,
                            backend: (any H3AttentionBackend)? = nil,
                            context: AttentionContext? = nil) -> MLXArray {
        let at: DType = fp32 ? .float32 : q.dtype
        let hasBatch = q.ndim == 4
        let qh = hasBatch ? q.transposed(0, 2, 1, 3).asType(at) : q.transposed(1, 0, 2).expandedDimensions(axis: 0).asType(at)
        let kh = hasBatch ? k.transposed(0, 2, 1, 3).asType(at) : k.transposed(1, 0, 2).expandedDimensions(axis: 0).asType(at)
        let vh = hasBatch ? v.transposed(0, 2, 1, 3).asType(at) : v.transposed(1, 0, 2).expandedDimensions(axis: 0).asType(at)

        let scale = 1.0 / Float(headDim).squareRoot()

        let out: MLXArray
        if let backend, let context, !hasBatch {
            out = backend.attend(queries: qh[0], keys: kh[0], values: vh[0],
                                 scale: scale, mask: nil, context: context)
                .expandedDimensions(axis: 0)
        } else {
            out = MLXFast.scaledDotProductAttention(
                queries: qh, keys: kh, values: vh, scale: scale, mask: nil)
        }

        if hasBatch {
            return out.transposed(0, 2, 1, 3).asType(q.dtype).reshaped([q.dim(0), q.dim(1), q.dim(2) * headDim])
        } else {
            return out.squeezed(axis: 0).transposed(1, 0, 2).asType(q.dtype).reshaped([q.dim(0), q.dim(1) * headDim])
        }
    }

    /// `x` is `[S, hidden]` or `[B, S, hidden]`.
    ///
    /// - Parameter context: optional information for a custom attention backend.
    func callAsFunction(_ x: MLXArray, ropeTable: MLXArray?,
                               context: AttentionContext? = nil) -> MLXArray {
        let qkv = matmul(x, qkvWeight.T)
        let qkvParts = qkv.split(parts: 3, axis: -1)

        let targetShape = qkvParts[0].shape.dropLast() + [heads, headDim]
        var q = qkvParts[0].reshaped(targetShape)
        var k = qkvParts[1].reshaped(targetShape)
        let v = qkvParts[2].reshaped(targetShape)

        // RMSNorm is applied per head BEFORE rope, as the fused kernel does.
        q = qNorm(q)
        k = kNorm(k)
        if let ropeTable {
            q = SplitHalfRoPE.apply(q, table: ropeTable)
            k = SplitHalfRoPE.apply(k, table: ropeTable)
        }

        let merged = Self.sdpa(q: q, k: k, v: v, headDim: headDim, fp32: fp32Attention,
                               backend: backend, context: context)
        return matmul(merged, outWeight.T)
    }
}

/// `fc2(silu(gate) * up)` where `fc1` emits `2 * ffn` and gate is the first
/// half of the split.
struct H3MLP {
    let fc1: MLXArray   // [2 * ffn, hidden]
    let fc2: MLXArray   // [hidden, ffn]

    init(fc1: MLXArray, fc2: MLXArray) {
        self.fc1 = fc1
        self.fc2 = fc2
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let h = matmul(x, fc1.T)
        let parts = h.split(parts: 2, axis: -1)
        let gate = parts[0]
        let up = parts[1]
        return matmul(silu(gate) * up, fc2.T)
    }
}

/// One transformer block.
///
///     shift_msa, scale_msa, gate_msa, shift_mlp, scale_mlp, gate_mlp = adaln(t_emb)
///     h = modScaleShift(norm1(x), shift_msa, scale_msa)
///     x = modGate(x, gate_msa, attn(h))
///     h = modScaleShift(norm2(x), shift_mlp, scale_mlp)
///     x = modGate(x, gate_mlp, mlp(h))
///
/// The reference mutates `x` in place and returns the same object. We return a
/// new array — functionally identical, and MLX has no in-place residual to
/// preserve.
struct H3TransformerBlock {
    let norm1: H3RMSNorm
    let norm2: H3RMSNorm
    let attn: AttentionLayer
    let mlp: H3MLP
    let adaln: AdalnProj

    init(norm1: H3RMSNorm, norm2: H3RMSNorm, attn: AttentionLayer,
                mlp: H3MLP, adaln: AdalnProj) {
        self.norm1 = norm1
        self.norm2 = norm2
        self.attn = attn
        self.mlp = mlp
        self.adaln = adaln
    }

    func callAsFunction(_ x: MLXArray, tEmb: MLXArray, index: ModulationIndex,
                               ropeTable: MLXArray?,
                               context: AttentionContext? = nil) -> MLXArray {
        let m = adaln(tEmb)
        precondition(m.count == 6, "H3TransformerBlock AdaLN must expand to 6, got \(m.count)")

        func norm(_ v: MLXArray, _ n: H3RMSNorm, _ shift: MLXArray,
                  _ scale: MLXArray) -> MLXArray {
            modScaleShift(n(v), shift: shift, scale: scale, index: index)
        }
        func gated(_ v: MLXArray, _ gate: MLXArray, _ other: MLXArray) -> MLXArray {
            modGate(v, gate: gate, other: other, index: index)
        }

        let h1 = norm(x, norm1, m[0], m[1])
        let x1 = gated(x, m[2], attn(h1, ropeTable: ropeTable, context: context))
        let h2 = norm(x1, norm2, m[3], m[4])
        return gated(x1, m[5], mlp(h2))
    }
}

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Kammerich


// Construction from the indexed SafeTensors checkpoint lives beside the
// Transformer implementation. This keeps the paper-facing component a single
// source of truth: no separate builder layer is needed.

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
struct TimeEmbedder {
    let projInWeight: MLXArray
    let projInBias: MLXArray?
    let projOutWeight: MLXArray
    let projOutBias: MLXArray?
    let inputDim: Int

    init(projInWeight: MLXArray, projInBias: MLXArray?,
                projOutWeight: MLXArray, projOutBias: MLXArray?, inputDim: Int) {
        self.projInWeight = projInWeight
        self.projInBias = projInBias
        self.projOutWeight = projOutWeight
        self.projOutBias = projOutBias
        self.inputDim = inputDim
    }

    /// `t` is `[M]` timestep values in [0, 1].
    func callAsFunction(_ t: MLXArray) -> MLXArray {
        var h = matmul(sinusoid(t), projInWeight.T)
        if let projInBias { h = h + projInBias }
        h = silu(h)
        var o = matmul(h, projOutWeight.T)
        if let projOutBias { o = o + projOutBias }
        return o
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

/// Final layer: `video_out` / `audio_out` heads over the target segments.
///
/// The heads are the model export's **fp32 island**. Casting them to bf16 with
/// everything else silently changes the output.
///
/// Its AdaLN has `modalities = 1`, unlike a block's 3 — so `ModSegment.row`
/// here is the **timestep row alone**, not `timestepRow * 3 + tag`.
struct FinalLayer {
    let norm: H3RMSNorm
    let adaln: AdalnProj
    let videoOutWeight: MLXArray
    let videoOutBias: MLXArray?
    let audioOutWeight: MLXArray
    let audioOutBias: MLXArray?

    init(norm: H3RMSNorm, adaln: AdalnProj,
                videoOutWeight: MLXArray, videoOutBias: MLXArray?,
                audioOutWeight: MLXArray, audioOutBias: MLXArray?) {
        self.norm = norm
        self.adaln = adaln
        self.videoOutWeight = videoOutWeight
        self.videoOutBias = videoOutBias
        self.audioOutWeight = audioOutWeight
        self.audioOutBias = audioOutBias
    }

    /// `seg` entries are `(start, stop, modRow)`.
    func callAsFunction(_ h: MLXArray, tEmb: MLXArray,
                               videoSeg: ModSegment, audioSeg: ModSegment)
        -> (video: MLXArray, audio: MLXArray) {
        let m = adaln(tEmb)
        precondition(m.count == 2, "FinalLayer AdaLN must expand to 2, got \(m.count)")
        let shift = m[0], scale = m[1]

        func head(_ seg: ModSegment, _ w: MLXArray, _ b: MLXArray?) -> MLXArray {
            let slice = h.ndim == 3 ? h[0..., seg.start ..< seg.stop] : h[seg.start ..< seg.stop]
            let sc = scale[seg.row].expandedDimensions(axis: 0)
            let sh = shift[seg.row].expandedDimensions(axis: 0)
            let x = (norm(slice) * (1.0 + sc) + sh).asType(.float32)
            var o = matmul(x, w.asType(.float32).T)
            if let b { o = o + b.asType(.float32) }
            return o
        }
        return (head(videoSeg, videoOutWeight, videoOutBias),
                head(audioSeg, audioOutWeight, audioOutBias))
    }
}

/// The assembled H3 Base Omni Transformer. The tokenizer, text encoder and two
/// VAEs remain separate paper components and are connected by H3BaseModel.
struct H3OmniTransformer {
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
    let conditionProj: (weight: MLXArray, bias: MLXArray?)
    let videoPatchProj: (weight: MLXArray, bias: MLXArray?)
    let audioPatchProj: (weight: MLXArray, bias: MLXArray?)
    let tokenRefiner: TokenRefiner
    let timeEmbedder: TimeEmbedder
    let blocks: [H3TransformerBlock]
    let finalLayer: FinalLayer
    let ropeInvFreq: MLXArray
    /// The dtype the block stack runs in. H3 Base uses BF16 for its encoded
    /// conditions and denoising path.
    let computeDType: DType

    init(config: H3Configuration,
                conditionProj: (weight: MLXArray, bias: MLXArray?),
                videoPatchProj: (weight: MLXArray, bias: MLXArray?),
                audioPatchProj: (weight: MLXArray, bias: MLXArray?),
                tokenRefiner: TokenRefiner, timeEmbedder: TimeEmbedder,
                blocks: [H3TransformerBlock], finalLayer: FinalLayer, ropeInvFreq: MLXArray,
                computeDType: DType = .bfloat16) {
        self.config = config
        self.conditionProj = conditionProj
        self.videoPatchProj = videoPatchProj
        self.audioPatchProj = audioPatchProj
        self.tokenRefiner = tokenRefiner
        self.timeEmbedder = timeEmbedder
        self.blocks = blocks
        self.finalLayer = finalLayer
        self.ropeInvFreq = ropeInvFreq
        self.computeDType = computeDType
    }

    private func linear(_ x: MLXArray, _ p: (weight: MLXArray, bias: MLXArray?)) -> MLXArray {
        var o = matmul(x, p.weight.T)
        if let b = p.bias { o = o + b }
        return o
    }

    /// Precompute the exact prompt- and geometry-invariant DiT inputs for one
    /// render. Call once before the sampler loop and pass the result to every
    /// velocity invocation in that loop.
    func prepareRender(
        textEmbeddings: MLXArray,
        layout: H3Sequence
    ) throws -> RenderState {
        precondition(layout.textTokens == textEmbeddings.dim(1))
        let textStates = linear(textEmbeddings[0].asType(computeDType), conditionProj)
        let refined = tokenRefiner(textStates)
        let pos = MLXArray(layout.positionIds.map { Float($0) }, [layout.totalTokens, 3])
        let rope = H3RoPE.rotationTable(
            angles: H3RoPE.angles(positionIds: pos, invFreq: ropeInvFreq)
        ).asType(computeDType)
        return RenderState(layout: layout, textTokenCount: textEmbeddings.dim(1), textStates: textStates,
                           refined: refined, ropeTable: rope)
    }

    /// One forward pass, in packed-row space.
    ///
    /// Returns the final layer's raw video and audio head outputs. The public
    /// velocity method reshapes those outputs back into latent tensors.
    ///
    /// - Parameters:
    ///   - videoLatent:    ///   - audioLatent: `[1,32,2,audioT]`
    ///   - textEmbeddings: `[1, textLen, textDim]` — output of the H3 Encoder
    ///   - layout: carries the segment table and `[S,3]` position ids
    func packedForward(videoLatent: MLXArray, audioLatent: MLXArray,
                              textEmbeddings: MLXArray, layout: H3Sequence,
                              plan: TimestepPlan, index: ModulationIndex,
                              renderState: RenderState? = nil,
                              condVideo: MLXArray? = nil,
                              condAudio: MLXArray? = nil)
        throws -> (video: MLXArray, audio: MLXArray) {

        // Text conditioning is projected in the transformer's working dtype.
        let textStates: MLXArray
        let refined: MLXArray
        if let renderState {
            precondition(renderState.layout == layout && renderState.textTokenCount == textEmbeddings.dim(1),
                         "RenderState does not match this render's sequence or text length")
            refined = renderState.refined
            textStates = renderState.textStates
        } else {
            textStates = linear(textEmbeddings[0].asType(computeDType), conditionProj)
            refined = tokenRefiner(textStates)
        }
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
        let videoEmbed = linear(concatenated(allVideoRows, axis: 0), videoPatchProj)

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
        let audioEmbed = linear(concatenated(allAudioRows, axis: 0), audioPatchProj)

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
        var h = concatenated(hSegments, axis: 0)

        precondition(h.dim(0) == layout.totalTokens,
                     "packed \(h.dim(0)) rows, layout says \(layout.totalTokens)")

        let tEmbFP32 = timeEmbedder(MLXArray(plan.values))
        let tEmb = tEmbFP32.asType(dtype)

        let table: MLXArray
        if let renderState {
            table = renderState.ropeTable
        } else {
            let pos = MLXArray(layout.positionIds.map { Float($0) }, [layout.totalTokens, 3])
            table = H3RoPE.rotationTable(
                angles: H3RoPE.angles(positionIds: pos, invFreq: ropeInvFreq)).asType(dtype)
        }

        // H3 Base currently uses the dense MLX attention path. The optional
        // backend seam stays inside AttentionLayer so future Metal kernels do
        // not change this model/evaluator boundary.
        for block in blocks {
            h = block(h, tEmb: tEmb, index: index, ropeTable: table, context: nil)
        }

        // The final layer's AdaLN has one modality, so these rows are timestep
        // rows — not the `row * 3 + tag` a block uses.
        let videoSeg = ModSegment(start: layout.videoRange.lowerBound,
                                  stop: layout.videoRange.upperBound, row: plan.row(for: .video))
        let audioSeg = ModSegment(start: layout.audioRange.lowerBound,
                                  stop: layout.audioRange.upperBound, row: plan.row(for: .audio))
        let (v, a) = finalLayer(h, tEmb: tEmb, videoSeg: videoSeg, audioSeg: audioSeg)
        return (v, a)
    }

    /// Latent-shaped velocity for one sampler step, matching the reference's
    /// return value exactly.
    ///
    /// Two sign conventions are baked in and neither is cosmetic: **both streams
    /// are negated**, and audio is additionally scaled by `d(sigma_a)/d(sigma_v)`
    /// so that the single flat ODE the sampler integrates is each stream's true
    /// ODE on its own shifted schedule.
    func velocity(videoLatent: MLXArray, audioLatent: MLXArray,
                          textEmbeddings: MLXArray, sigmaVideo: Double,
                          geometry: H3LatentGeometry, textTags: [Int]? = nil,
                          condVideo: MLXArray? = nil,
                          condAudio: MLXArray? = nil,
                          renderState: RenderState? = nil) throws -> (video: MLXArray, audio: MLXArray) {
        guard let layout = renderState?.layout else {
            throw H3EvaluatorError.invalidRequest(
                rule: "missing H3 render layout",
                detail: "velocity was called before the task-specific packed sequence was prepared",
                remedy: "prepare the FL2VA or Ref2VA render state before sampling.")
        }
        let plan = TimestepPlan(sigmaVideo: sigmaVideo, segments: layout.segments)
        let index = ModulationIndex(layout: layout, plan: plan, textTags: textTags)
        let (v, a) = try packedForward(videoLatent: videoLatent, audioLatent: audioLatent,
                                   textEmbeddings: textEmbeddings, layout: layout, plan: plan,
                                   index: index,
                                   renderState: renderState,
                                   condVideo: condVideo,
                                   condAudio: condAudio)
        let video = H3Packing.unpatchifyVideo(v, t: geometry.latentT,
                                              h: geometry.latentH / config.patchSize[1],
                                              w: geometry.latentW / config.patchSize[2],
                                              channels: config.videoLatentDim,
                                              patch: config.patchSize)
        let audio = H3Packing.unpackAudio(a)
        return (-video, MLXArray(-plan.audioSlope) * audio)
    }

}

/// Two pre-norm blocks with plain residuals, then a final RMSNorm. No AdaLN,
/// no RoPE — the refiner sees text only.
struct TokenRefiner {
    struct Block {
        let norm1: H3RMSNorm
        let norm2: H3RMSNorm
        let attn: AttentionLayer
        let mlp: H3MLP
        init(norm1: H3RMSNorm, norm2: H3RMSNorm, attn: AttentionLayer, mlp: H3MLP) {
            self.norm1 = norm1
            self.norm2 = norm2
            self.attn = attn
            self.mlp = mlp
        }
        func callAsFunction(_ x: MLXArray) -> MLXArray {
            let a = attn(norm1(x), ropeTable: nil) + x
            return mlp(norm2(a)) + a
        }
    }
    let blocks: [Block]
    let finalNorm: H3RMSNorm
    init(blocks: [Block], finalNorm: H3RMSNorm) {
        self.blocks = blocks
        self.finalNorm = finalNorm
    }
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = x
        for b in blocks { h = b(h) }
        return finalNorm(h)
    }
}

/// Materializes the shared H3 Omni Transformer directly from the indexed
/// SafeTensors checkpoint. Keeping this initializer here makes the model's
/// construction path as explicit as its forward path.
extension H3OmniTransformer {
    /// - Parameter computeDType: dtype used by the Transformer blocks.
    /// - Parameter backend: one attention backend shared by every block.
    init(
        weights: H3BaseWeights,
        computeDType: DType = .bfloat16,
        fp32Attention: Bool = false,
        keepAdaLNFP32Resident: Bool = false,
        backend: any H3AttentionBackend = SDPABackend()
    ) throws {
        let c = weights.config
        func w(_ name: String) throws -> MLXArray { try weights.tensor(name) }

        func attention(_ prefix: String) throws -> AttentionLayer {
            AttentionLayer(
                qkvWeight: try w(prefix + "attn.qkv_proj.weight"),
                outWeight: try w(prefix + "attn.out_proj.weight"),
                qNormWeight: try w(prefix + "attn.q_norm.weight"),
                kNormWeight: try w(prefix + "attn.k_norm.weight"),
                heads: c.numHeads,
                headDim: c.headDim,
                eps: c.qkNormEps,
                fp32Attention: fp32Attention,
                backend: backend)
        }

        func mlp(_ prefix: String) throws -> H3MLP {
            H3MLP(
                fc1: try w(prefix + "mlp.fc1.weight"),
                fc2: try w(prefix + "mlp.fc2.weight"))
        }

        func norm(_ name: String, _ eps: Float) throws -> H3RMSNorm {
            H3RMSNorm(weight: try w(name), eps: eps)
        }

        var blocks: [H3TransformerBlock] = []
        blocks.reserveCapacity(c.numLayers)
        for index in 0 ..< c.numLayers {
            let prefix = "blocks.\(index)."
            let adaln = AdalnProj(
                weight: try w(prefix + "adaln_proj.linear.weight"),
                bias: try w(prefix + "adaln_proj.linear.bias"),
                expand: 6,
                modalities: 3,
                hidden: c.hiddenSize,
                keepFP32Resident: keepAdaLNFP32Resident)
            blocks.append(H3TransformerBlock(
                norm1: try norm(prefix + "norm1.weight", c.normEps),
                norm2: try norm(prefix + "norm2.weight", c.normEps),
                attn: try attention(prefix),
                mlp: try mlp(prefix),
                adaln: adaln))
        }

        var refiner: [TokenRefiner.Block] = []
        refiner.reserveCapacity(c.tokenRefinerLayers)
        for index in 0 ..< c.tokenRefinerLayers {
            let prefix = "token_refiner.blocks.\(index)."
            refiner.append(TokenRefiner.Block(
                norm1: try norm(prefix + "norm1.weight", c.normEps),
                norm2: try norm(prefix + "norm2.weight", c.normEps),
                attn: try attention(prefix),
                mlp: try mlp(prefix)))
        }

        let finalAdaln = AdalnProj(
            weight: try w("final_layer.adaln_proj.linear.weight"),
            bias: try w("final_layer.adaln_proj.linear.bias"),
            expand: 2,
            modalities: 1,
            hidden: c.hiddenSize)
        let final = FinalLayer(
            norm: try norm("final_layer.norm.weight", c.finalNormEps),
            adaln: finalAdaln,
            videoOutWeight: try w("final_layer.video_out.weight"),
            videoOutBias: try w("final_layer.video_out.bias"),
            audioOutWeight: try w("final_layer.audio_out.weight"),
            audioOutBias: try w("final_layer.audio_out.bias"))

        self.init(
            config: c,
            conditionProj: (try w("condition_proj.weight"), try w("condition_proj.bias")),
            videoPatchProj: (try w("video_patch_proj.weight"), try w("video_patch_proj.bias")),
            audioPatchProj: (try w("audio_patch_proj.weight"), try w("audio_patch_proj.bias")),
            tokenRefiner: TokenRefiner(
                blocks: refiner,
                finalNorm: try norm("token_refiner.final_norm.weight", c.finalNormEps)),
            timeEmbedder: TimeEmbedder(
                projInWeight: try w("time_embedder.proj_in.weight"),
                projInBias: try w("time_embedder.proj_in.bias"),
                projOutWeight: try w("time_embedder.proj_out.weight"),
                projOutBias: try w("time_embedder.proj_out.bias"),
                inputDim: c.timestepInputDim),
            blocks: blocks,
            finalLayer: final,
            ropeInvFreq: try w("rope.inv_freq"),
            computeDType: computeDType)
    }
}

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Kammerich


/// Qwen2 byte-level BPE — the tokenizer H3's conditioning encoder expects.
///
/// MiniMax-H3 uses it in its plainest form. `MiniMaxH3Tokenizer` in the
/// reference calls `tok(text, add_special_tokens=False)` and adds **nothing**:
/// no chat template, no BOS, no EOS. The `<|im_start|>user\n…` wrapper that
/// other Qwen3-VL consumers apply is not used here, and adding it would shift
/// every position and change the conditioning.
///
/// Empty input is the one special case: the reference substitutes a single pad
/// token (151643) rather than an empty sequence.
