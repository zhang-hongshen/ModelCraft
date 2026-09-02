//
//  H3Conditioning.swift
//  ModelCraft
//
//  Created by Hongshen on 27/8/26.
//

import Foundation
import MLX

/// Latent shapes used by the H3 Base Visual VAE and Audio VAE.
struct H3LatentGeometry: Sendable {
    let frameCount: Int
    let latentT: Int
    let audioT: Int
    let latentH: Int
    let latentW: Int
    let configuration: H3Configuration

    /// Snap a requested frame count up onto H3's temporal lattice.
    static func alignFrameCount(
        _ length: Int,
        configuration: H3Configuration = .presetH3BaseFL2VA
    ) -> Int {
        let n = max(configuration.frameLatticeOffset, length)
        let k = Int((Double(n - configuration.frameLatticeOffset)
            / Double(configuration.frameLattice)).rounded(.up))
        return configuration.frameLatticeOffset + k * configuration.frameLattice
    }

    /// `latentT = 5(F-offset)/lattice + 2`, `audioT = round(F/fps * 40)`.
    init(
        width: Int,
        height: Int,
        length: Int,
        configuration: H3Configuration = .presetH3BaseFL2VA
    ) {
        let f = Self.alignFrameCount(length, configuration: configuration)
        self.frameCount = f
        self.latentT = 5 * (f - configuration.frameLatticeOffset)
            / configuration.frameLattice + 2
        self.audioT = Int((Double(f) / Double(configuration.frameRate)
            * Double(configuration.audioLatentFrameRate)).rounded())
        self.latentH = height / configuration.visualSpatialCompression
        self.latentW = width / configuration.visualSpatialCompression
        self.configuration = configuration
    }

    /// `[B, 24, latentT, H/16, W/16]`
    func videoLatentShape(batch: Int = 1) -> [Int] {
        [batch, configuration.videoLatentDim, latentT, latentH, latentW]
    }

    /// `[B, 32, 2, audioT]` — the 2 is not a batch or channel axis; it is part
    /// of the audio latent's own layout.
    func audioLatentShape(batch: Int = 1) -> [Int] {
        [batch, configuration.audioLatentDim, 2, audioT]
    }

    /// Video tokens after patchify: `latentT * (H/2) * (W/2)`.
    var videoTokens: Int {
        latentT * (latentH / configuration.patchSize[1])
            * (latentW / configuration.patchSize[2])
    }

    /// Audio tokens: `2 * audioT`.
    var audioTokens: Int { 2 * audioT }

    var inTrainedRange: Bool {
        configuration.minimumFrameCount...configuration.maximumFrameCount ~= frameCount
    }
}


/// The modality tag an AdaLN row carries. Fixed by the reference's `seg_tag`
/// table in `comfy/ldm/minimax/model.py`: **video 0, text 1, audio 2**.
enum ModalityTag: Int, Sendable {
    case video = 0
    case text = 1
    case audio = 2
}

/// A kind of span in the packed sequence.
///
/// The kind decides three separate things — which embedding stream fills the
/// rows, which modality tag the AdaLN row uses, and which timestep the span
/// runs on. They do not coincide: `cond` rows are video-tagged but sit at a
/// near-1.0 timestep of their own.
enum H3SequenceSegmentKind: String, Sendable, Equatable {
    case text
    case visualCondition
    case audioCondition
    case audio
    case video

    var modality: ModalityTag {
        switch self {
        case .text: .text
        case .audio, .audioCondition: .audio
        case .video, .visualCondition: .video
        }
    }

    /// Whether the span's rows come from the video patch projection.
    var isVideoStream: Bool { self == .video || self == .visualCondition }

    var isAudioStream: Bool { self == .audio || self == .audioCondition }
}

struct H3SequenceSegment: Sendable, Equatable {
    let start: Int
    let stop: Int
    let kind: H3SequenceSegmentKind
    init(start: Int, stop: Int, kind: H3SequenceSegmentKind) {
        self.start = start
        self.stop = stop
        self.kind = kind
    }
    var count: Int { stop - start }
}

/// RoPE position coordinates.
///
/// Positions are **not** integer token indices. The spatial axes are
/// area-normalized so that a 480x864 render and a 720x720 render of the same
/// pixel count land on comparable coordinates, and the temporal axis advances in
/// rescaled frame spans rather than by one per token. Everything here is
/// computed in Double because the reference builds `position_ids` in float64
/// and only narrows to fp32 inside `rope_freqs`.
enum PositionGrid {
    /// Frames represented by each video latent token, cycling with period 5.
    /// The first latent frame covers 1 source frame, the rest cover 4.
    static let framesPerToken = [1, 4, 4, 4, 4]
    /// Temporal spans are scaled by 5/3 before being accumulated.
    static let frameRescale = 5.0 / 3.0

    /// `linspace((1-ratio)/2, (1+ratio)/2, dim/patch, endpoint=False) * 32`
    /// where `ratio = dim / sqrt(h*w)`.
    static func axis(dim: Int, patch: Int, sqrtArea: Double) throws -> [Double] {
        let ratio = Double(dim) / sqrtArea
        let n = dim / patch
        guard n > 0 else {
            throw H3EvaluatorError.dimensionOffGrid(width: dim, height: dim, multiple: patch)
        }
        let step = ratio / Double(n)
        let origin = (1.0 - ratio) / 2.0
        return (0 ..< n).map { (Double($0) * step + origin) * 32.0 }
    }

    /// One latent frame's `(h, w)` coordinates, row-major over the 2x2-patch
    /// grid, plus the w axis on its own (the audio grid pins to its extremes).
    static func frameGrid(h: Int, w: Int, patch: Int = 2)
        throws -> (rows: [(h: Double, w: Double)], wAxis: [Double]) {
        let area = (Double(h) * Double(w)).squareRoot()
        let hAxis = try axis(dim: h, patch: patch, sqrtArea: area)
        let wAxis = try axis(dim: w, patch: patch, sqrtArea: area)
        var rows: [(h: Double, w: Double)] = []
        rows.reserveCapacity(hAxis.count * wAxis.count)
        for hv in hAxis { for wv in wAxis { rows.append((hv, wv)) } }
        return (rows, wAxis)
    }

    /// `origin + exclusive_cumsum(spans)`, one t coordinate per latent frame.
    static func videoTGrid(_ n: Int, origin: Double) -> [Double] {
        var out = [Double](repeating: 0, count: n)
        var acc = origin
        for k in 0 ..< n {
            out[k] = acc
            acc += frameRescale * Double(framesPerToken[k % framesPerToken.count])
        }
        return out
    }

    /// Total temporal extent of `n` video latent frames.
    static func videoTSpan(_ n: Int) -> Double {
        (0 ..< n).reduce(0.0) { $0 + frameRescale * Double(framesPerToken[$1 % framesPerToken.count]) }
    }

    /// The t coordinate of a keyframe anchored at pixel frame `p`.
    ///
    /// Latent token `k` spans `frameRescale * framesPerToken[k % 5]` and covers
    /// `framesPerToken[k % 5]` pixel frames, so cumulative time at pixel frame
    /// `p` is exactly `frameRescale * p`. That identity is what makes an anchor
    /// away from the ends *defined* rather than guessed: substituting
    /// `p = frameCount - 1` reproduces the reference's own last-frame
    /// expression, because `sum(framesPerToken over latentT) == frameCount` on
    /// the 17k+5 lattice.
    ///
    ///     textTokens + frameRescale * (frameCount - 1)
    ///       == textTokens + frameRescale * frameCount - frameRescale
    ///       == textTokens + videoTSpan(latentT) - frameRescale
    ///
    /// `p` is a **pixel** frame index on the aligned lattice, not a latent one,
    /// and the caller is responsible for having aligned it. Range is not checked
    /// here; `H3Sequence` refuses out-of-range anchors where it knows the
    /// frame count.
    static func condT(textTokens: Int, latentT: Int, frameCount: Int,
                              pixelIndex p: Int) -> Double {
        if p == 0 { return Double(textTokens) }
        if p == frameCount - 1 { return Double(textTokens) + videoTSpan(latentT) - frameRescale }
        return Double(textTokens) + frameRescale * Double(p)
    }
}

struct KeyframeConfig: Sendable, Equatable {
    let resolvedFrameIndex: Int
    init(resolvedFrameIndex: Int) {
        self.resolvedFrameIndex = resolvedFrameIndex
    }
}

/// Geometry of one Ref2VA block in the user's reference order.
///
/// A video may carry both audio and visual rows. An image carries one visual
/// latent frame; an audio reference carries audio rows only.
struct H3ReferenceSequenceBlock: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case image
        case video
        case audio
    }

    struct VisualGeometry: Sendable, Equatable {
        let latentT: Int
        let latentH: Int
        let latentW: Int
    }

    let kind: Kind
    let visual: VisualGeometry?
    let audioT: Int

    init(kind: Kind, visual: VisualGeometry? = nil, audioT: Int = 0) {
        self.kind = kind
        self.visual = visual
        self.audioT = audioT
    }
}

/// The packed sequence a DiT block actually sees.
///
/// **Order is text | visual conditions | audio | video** — target audio then
/// target video, always the last two segments.
///
/// **There is no batch dimension inside the stack.** Blocks operate on
/// `[S, hidden]`, and slices come from the segment table.
struct H3Sequence: Sendable, Equatable {
    let textTokens: Int
    let audioTokens: Int
    let videoTokens: Int
    let segments: [H3SequenceSegment]
    /// Row-major `[S, 3]` of `(t, h, w)`, in float64 as the reference builds it.
    let positionIds: [Double]

    /// - Throws: `H3EvaluatorError.keyframeIndex` for an anchor off the timeline.
    init(textTokens: Int, geometry: H3LatentGeometry,
                keyframes: [KeyframeConfig] = []) throws {
        self.textTokens = textTokens
        self.audioTokens = geometry.audioTokens
        self.videoTokens = geometry.videoTokens

        let patch = geometry.configuration.patchSize[1]
        let (frame, wAxis) = try PositionGrid.frameGrid(
            h: geometry.latentH,
            w: geometry.latentW,
            patch: patch)
        let wLow = wAxis.first ?? 0
        let wHigh = wAxis.last ?? 0
        var pos = [Double]()
        var segments: [H3SequenceSegment] = []
        var row = 0

        // 1. Text segment
        segments.append(H3SequenceSegment(start: row, stop: row + textTokens, kind: .text))
        for i in 0 ..< textTokens { pos.append(contentsOf: [Double(i), 0, 0]) }
        row += textTokens
        let cursor = Double(textTokens)

        // 2. Keyframes (FL2VA)
        for kf in keyframes {
            guard kf.resolvedFrameIndex >= 0, kf.resolvedFrameIndex < geometry.frameCount else {
                throw H3EvaluatorError.keyframeIndex(index: kf.resolvedFrameIndex,
                                            frameCount: geometry.frameCount)
            }
            let condT = PositionGrid.condT(textTokens: textTokens, latentT: geometry.latentT,
                                           frameCount: geometry.frameCount,
                                           pixelIndex: kf.resolvedFrameIndex)
            segments.append(H3SequenceSegment(
                start: row,
                stop: row + frame.count,
                kind: .visualCondition))
            for r in frame { pos.append(contentsOf: [condT, r.h, r.w]) }
            row += frame.count
        }

        // 3. Target audio (always second to last)
        segments.append(H3SequenceSegment(start: row, stop: row + audioTokens, kind: .audio))
        for w in [wLow, wHigh] {
            for i in 0 ..< geometry.audioT { pos.append(contentsOf: [cursor + Double(i), 0, w]) }
        }
        row += audioTokens

        // 4. Target video (always last)
        segments.append(H3SequenceSegment(start: row, stop: row + videoTokens, kind: .video))
        for t in PositionGrid.videoTGrid(geometry.latentT, origin: cursor) {
            for r in frame { pos.append(contentsOf: [t, r.h, r.w]) }
        }
        row += videoTokens

        self.positionIds = pos
        self.segments = segments
    }

    /// Ref2VA layout: text, ordered reference blocks, target audio, target video.
    init(
        textTokens: Int,
        geometry: H3LatentGeometry,
        references: [H3ReferenceSequenceBlock]
    ) throws {
        self.textTokens = textTokens
        self.audioTokens = geometry.audioTokens
        self.videoTokens = geometry.videoTokens

        let patch = geometry.configuration.patchSize[1]
        let (targetFrame, targetWAxis) = try PositionGrid.frameGrid(
            h: geometry.latentH,
            w: geometry.latentW,
            patch: patch)
        var pos = [Double]()
        var segments: [H3SequenceSegment] = []
        var row = 0

        segments.append(H3SequenceSegment(
            start: row,
            stop: row + textTokens,
            kind: .text))
        for index in 0 ..< textTokens {
            pos.append(contentsOf: [Double(index), 0, 0])
        }
        row += textTokens
        var rotaryTime = Double(textTokens)

        func appendAudio(tokensPerChannel: Int, widthAxis: [Double]) {
            guard tokensPerChannel > 0 else { return }
            let start = row
            let low = widthAxis.first ?? 0
            let high = widthAxis.last ?? 0
            for width in [low, high] {
                for index in 0 ..< tokensPerChannel {
                    pos.append(contentsOf: [rotaryTime + Double(index), 0, width])
                }
            }
            row += 2 * tokensPerChannel
            segments.append(H3SequenceSegment(
                start: start,
                stop: row,
                kind: .audioCondition))
        }

        func appendVisual(_ visual: H3ReferenceSequenceBlock.VisualGeometry) throws -> Double {
            let start = row
            let (frame, _) = try PositionGrid.frameGrid(
                h: visual.latentH,
                w: visual.latentW,
                patch: patch)
            for time in PositionGrid.videoTGrid(visual.latentT, origin: rotaryTime) {
                for point in frame {
                    pos.append(contentsOf: [time, point.h, point.w])
                }
            }
            row += visual.latentT * frame.count
            segments.append(H3SequenceSegment(
                start: start,
                stop: row,
                kind: .visualCondition))
            return PositionGrid.videoTSpan(visual.latentT)
        }

        for reference in references {
            switch reference.kind {
            case .image:
                guard let visual = reference.visual else {
                    throw H3EvaluatorError.invalidRequest(
                        rule: "missing image reference latents",
                        detail: "an image reference has no Visual VAE geometry",
                        remedy: "encode every image reference before building the Ref2VA sequence.")
                }
                _ = try appendVisual(visual)
                // Official Ref2VA uses one integer rotary slot for a still.
                rotaryTime += 1.0

            case .audio:
                appendAudio(tokensPerChannel: reference.audioT, widthAxis: targetWAxis)
                rotaryTime += Double(reference.audioT)

            case .video:
                guard let visual = reference.visual else {
                    throw H3EvaluatorError.invalidRequest(
                        rule: "missing video reference latents",
                        detail: "a video reference has no Visual VAE geometry",
                        remedy: "encode every video reference before building the Ref2VA sequence.")
                }
                let origin = rotaryTime
                let (_, referenceWAxis) = try PositionGrid.frameGrid(
                    h: visual.latentH,
                    w: visual.latentW,
                    patch: patch)
                appendAudio(tokensPerChannel: reference.audioT, widthAxis: referenceWAxis)
                rotaryTime = origin
                let visualSpan = try appendVisual(visual)
                rotaryTime = origin + max(Double(reference.audioT), visualSpan)
            }
        }

        let targetAudioStart = row
        let targetLow = targetWAxis.first ?? 0
        let targetHigh = targetWAxis.last ?? 0
        for width in [targetLow, targetHigh] {
            for index in 0 ..< geometry.audioT {
                pos.append(contentsOf: [rotaryTime + Double(index), 0, width])
            }
        }
        row += geometry.audioTokens
        segments.append(H3SequenceSegment(
            start: targetAudioStart,
            stop: row,
            kind: .audio))

        let targetVideoStart = row
        for time in PositionGrid.videoTGrid(geometry.latentT, origin: rotaryTime) {
            for point in targetFrame {
                pos.append(contentsOf: [time, point.h, point.w])
            }
        }
        row += geometry.videoTokens
        segments.append(H3SequenceSegment(
            start: targetVideoStart,
            stop: row,
            kind: .video))

        self.positionIds = pos
        self.segments = segments
    }

    var totalTokens: Int { positionIds.count / 3 }

    /// Half-open ranges into the packed sequence, in packing order.
    var textRange: Range<Int> {
        let seg = segments.first { $0.kind == .text }!
        return seg.start ..< seg.stop
    }
    var audioRange: Range<Int> {
        let seg = segments.first { $0.kind == .audio }!
        return seg.start ..< seg.stop
    }
    var videoRange: Range<Int> {
        let seg = segments.first { $0.kind == .video }!
        return seg.start ..< seg.stop
    }

    /// [S, hidden] — the shape every block tap is recorded at.
    func blockShape(config: H3Configuration) -> [Int] { [totalTokens, config.hiddenSize] }
}



/// The flow-matching sigma schedule.
///
///     sigma(t) = shift * t / (1 + (shift - 1) * t),   t_i = 1 - i/steps
///
/// With `shift = 12` this is heavily back-loaded: 15 of 20 steps cover sigma
/// 1.0 -> 0.8, and the last step leaps 0.387 -> 0. **That is correct, not a
/// bug.** It matches the reference exactly at every step, and "fixing" it to a
/// linear schedule is a classic and expensive mistake.

struct H3Conditions {
    let videoRows: MLXArray?
    let audioRows: MLXArray?
    let keyframes: [KeyframeConfig]
    let references: [H3ReferenceSequenceBlock]
}

/// Encodes FL2VA conditions before the H3 Omni Transformer is sampled.
enum H3Conditioning {
    static func encodeFL2VAVisual(
        keyframes: [H3EvaluatorKeyframe],
        encoder: H3VisualVAEEncoder,
        width: Int,
        height: Int
    ) throws -> [MLXArray] {
        guard !keyframes.isEmpty else { return [] }

        return try keyframes.map { keyframe in
            let pixels = try H3IO.image(
                at: keyframe.image.path,
                fit: (width, height))
            let latent = encoder.encode(pixels)
            eval(latent)
            return latent
        }
    }

    static func assembleFL2VA(
        keyframes: [H3EvaluatorKeyframe],
        geometry: H3LatentGeometry,
        visualLatents: [MLXArray],
        seed: UInt64
    ) throws -> H3Conditions {
        guard visualLatents.count == keyframes.count else {
            throw H3EvaluatorError.invalidRequest(
                rule: "frame conditioning count mismatch",
                detail: "received \(visualLatents.count) latent(s) for \(keyframes.count) frame(s)",
                remedy: "provide one valid latent for every first/last frame.")
        }

        let anchors = keyframes.map {
            KeyframeConfig(resolvedFrameIndex: $0.frame)
        }
        let videoRows = try visualRows(
            visualLatents,
            augmentation: geometry.configuration.visualConditionNoise,
            seed: seed)

        return H3Conditions(
            videoRows: videoRows,
            audioRows: nil,
            keyframes: anchors,
            references: [])
    }

    static func visualRows(
        _ latents: [MLXArray],
        augmentation: Float,
        seed: UInt64? = nil
    ) throws -> MLXArray? {
        guard !latents.isEmpty else { return nil }
        let packed = latents.map {
            H3Packing.patchifyVideo($0.asType(.float32), patch: [1, 2, 2])
        }

        guard augmentation < 1.0 else {
            return concatenated(packed, axis: 0)
        }

        let seed = seed ?? UInt64.random(in: UInt64.min ... UInt64.max)
        let mixed = packed.enumerated().map { index, condition in
            let noise = MLXRandom.normal(
                condition.shape,
                key: MLXRandom.key(seed &+ UInt64(index)))
            return MLXArray(augmentation) * condition
                + MLXArray(1.0 - augmentation) * noise
        }
        return concatenated(mixed, axis: 0)
    }
}

// SPDX-License-Identifier: Apache-2.0


/// The Ref2VA condition encoders described by MiniMax H3 Base.
///
/// References remain in request order. Images and videos contribute H3 Encoder
/// vision tokens and Visual VAE rows; audio files and video soundtracks
/// contribute Audio VAE rows immediately before their associated video rows.
extension H3Conditioning {
    private static let videoSampleFPS = 2.0
    private static let temporalPatch = 2
    private static let conditionEncodeSeed: UInt64 = 42

    static func encodeText(
        prompt: String,
        references: [URL],
        encoder: H3Encoder,
        tokenizer: H3Tokenizer
    ) throws -> H3TextConditioningData {
        var elements: [H3Presentation.Element] = []
        var pictureIndex = 0
        var videoIndex = 0
        var audioIndex = 0

        for reference in references {
            switch try H3IO.decode(reference) {
            case .image(let image):
                pictureIndex += 1
                let (block, grid) = try visionBlock(
                    pixels: image.encoderPixels,
                    tower: encoder.visionEncoder)
                elements.append(.text("<Picture \(pictureIndex)>: "))
                elements.append(.vision(block, grid))

            case .audio:
                audioIndex += 1
                elements.append(.text("<Audio \(audioIndex)>: "))

            case .video(let video):
                if video.audio != nil {
                    audioIndex += 1
                    elements.append(.text("<Audio \(audioIndex)>: "))
                }

                videoIndex += 1
                elements.append(.text("<Video \(videoIndex)>: "))
                let sampled = try sampledVideoFrames(video.frames)
                let frameTensor = concatenated(sampled.frames, axis: 0)
                let config = H3VisionEncoderConfiguration()
                let (_, _, imageGrid) = H3VisionPreprocess.grid(
                    width: frameTensor.dim(2),
                    height: frameTensor.dim(1),
                    config: config)
                let grid = H3VisionGrid(
                    t: (sampled.frames.count + temporalPatch - 1) / temporalPatch,
                    h: imageGrid.h,
                    w: imageGrid.w)
                let patches = try H3VisionPreprocess.patches(
                    video: frameTensor,
                    grid: grid,
                    config: config)
                let encoded = encoder.visionEncoder(patches: patches, grid: grid)
                let tokensPerBlock = encoded.merged.dim(0) / grid.t

                for blockIndex in 0 ..< grid.t {
                    elements.append(.text(
                        "<\(timestamp(sampled.blockTimestamps[blockIndex])) seconds>"))
                    elements.append(.vision(
                        slice(
                            encoded,
                            blockIndex: blockIndex,
                            tokensPerBlock: tokensPerBlock),
                        H3VisionGrid(t: 1, h: grid.h, w: grid.w)))
                }
            }
        }

        elements.append(.text(prompt))
        let assembled = H3Presentation.assemble(
            elements: elements,
            tokenizer: tokenizer,
            encoder: encoder.textEncoder)
        let encoded = encoder.textEncoder(
            embeds: assembled.embeds,
            computeDType: .float32,
            positionIds: assembled.positionIds,
            visualSpans: assembled.spans.map { (start: $0.start, count: $0.size) },
            deepstack: assembled.deepstack)
        eval(encoded)
        return H3TextConditioningData(
            textEmbeddings: encoded,
            tags: assembled.tags)
    }

    static func encodeReferences(
        references: [URL],
        visualEncoder: H3VisualVAEEncoder,
        audioEncoder: H3AudioVAEEncoder,
        configuration: H3Configuration,
        seed: UInt64
    ) throws -> H3Conditions {
        precondition(configuration.task == .ref2va)
        var visualLatents: [MLXArray] = []
        var audioRows: [MLXArray] = []
        var blocks: [H3ReferenceSequenceBlock] = []

        for reference in references {
            let decoded = try H3IO.decode(reference)
            switch decoded {
            case .image(let image):
                let latent = visualEncoder.encode(
                    image.visualVAEPixels,
                    seed: conditionEncodeSeed)
                eval(latent)
                visualLatents.append(latent)
                blocks.append(H3ReferenceSequenceBlock(
                    kind: .image,
                    visual: geometry(of: latent)))

            case .audio(let audio):
                let rows = audioConditionRows(audio, encoder: audioEncoder)
                eval(rows)
                audioRows.append(rows)
                blocks.append(H3ReferenceSequenceBlock(
                    kind: .audio,
                    audioT: rows.dim(0) / 2))

            case .video(let video):
                let frameCount = alignedReferenceFrameCount(video.visualVAEPixels.dim(2))
                let pixels = VaeTiling.sliceDim(
                    video.visualVAEPixels,
                    dim: 2,
                    start: 0,
                    end: frameCount)
                let latent = visualEncoder.encode(
                    pixels,
                    seed: conditionEncodeSeed)
                eval(latent)
                visualLatents.append(latent)

                let soundtrackRows = video.audio.map {
                    audioConditionRows($0, encoder: audioEncoder)
                }
                if let soundtrackRows {
                    eval(soundtrackRows)
                    audioRows.append(soundtrackRows)
                }
                blocks.append(H3ReferenceSequenceBlock(
                    kind: .video,
                    visual: geometry(of: latent),
                    audioT: soundtrackRows.map { $0.dim(0) / 2 } ?? 0))
            }
        }

        let packedVisual = try H3Conditioning.visualRows(
            visualLatents,
            augmentation: configuration.visualConditionNoise,
            seed: seed)
        return H3Conditions(
            videoRows: packedVisual,
            audioRows: audioRows.isEmpty ? nil : concatenated(audioRows, axis: 0),
            keyframes: [],
            references: blocks)
    }

    private static func visionBlock(
        pixels: MLXArray,
        tower: H3VisionEncoder
    ) throws -> (H3Presentation.VisionBlock, H3VisionGrid) {
        let (width, height, grid) = H3VisionPreprocess.grid(
            width: pixels.dim(2),
            height: pixels.dim(1))
        guard width == pixels.dim(2), height == pixels.dim(1) else {
            throw H3EvaluatorError.mediaOffCanvas(
                path: "Ref2VA image reference",
                size: "\(pixels.dim(2))x\(pixels.dim(1))",
                remedy: "decode the reference on H3's 32-pixel vision grid.")
        }
        let patches = try H3VisionPreprocess.patches(image: pixels, grid: grid)
        let encoded = tower(patches: patches, grid: grid)
        return (
            H3Presentation.VisionBlock(
                merged: encoded.merged,
                deepstack: encoded.deepstack),
            grid)
    }

    private static func slice(
        _ encoded: H3VisionEncoder.Output,
        blockIndex: Int,
        tokensPerBlock: Int
    ) -> H3Presentation.VisionBlock {
        let range = (blockIndex * tokensPerBlock) ..< ((blockIndex + 1) * tokensPerBlock)
        return H3Presentation.VisionBlock(
            merged: encoded.merged[range],
            deepstack: encoded.deepstack.map { $0[range] })
    }

    private static func sampledVideoFrames(
        _ frames: [MLXArray]
    ) throws -> (frames: [MLXArray], blockTimestamps: [Double]) {
        let sampleStride = Double(H3Configuration.presetH3BaseRef2VA.frameRate) / videoSampleFPS
        var indices: [Int] = []
        var cursor = 0.0
        while Int(cursor.rounded()) < frames.count {
            let index = Int(cursor.rounded())
            if indices.last != index { indices.append(index) }
            cursor += sampleStride
        }
        guard indices.count >= temporalPatch else {
            throw H3EvaluatorError.invalidRequest(
                rule: "reference video is too short for the H3 Encoder",
                detail: "\(frames.count) normalized frame(s)",
                remedy: "provide at least two frames at the 2 fps reference sampling rate.")
        }

        var timestamps = indices.indices.map { Double($0) / videoSampleFPS }
        while timestamps.count % temporalPatch != 0 {
            timestamps.append(timestamps.last!)
        }
        let blocks = Swift.stride(from: 0, to: timestamps.count, by: temporalPatch).map {
            (timestamps[$0] + timestamps[$0 + temporalPatch - 1]) / 2.0
        }
        return (indices.map { frames[$0] }, blocks)
    }

    private static func timestamp(_ seconds: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), seconds)
    }

    private static func audioConditionRows(
        _ audio: H3DecodedAudio,
        encoder: H3AudioVAEEncoder
    ) -> MLXArray {
        let length = min(audio.samples[0].count, audio.samples[1].count)
        let samples = audio.samples.flatMap { Array($0.prefix(length)) }
        let waveform = MLXArray(samples, [1, 2, length])
        return H3Packing.packAudio(encoder.encode(waveform))
    }

    private static func geometry(
        of latent: MLXArray
    ) -> H3ReferenceSequenceBlock.VisualGeometry {
        H3ReferenceSequenceBlock.VisualGeometry(
            latentT: latent.dim(2),
            latentH: latent.dim(3),
            latentW: latent.dim(4))
    }

    /// Ref2VA snaps video references down to the VAE's `17n+5` lattice.
    private static func alignedReferenceFrameCount(_ count: Int) -> Int {
        max(1, (count - 5) / 17) * 17 + 5
    }
}
