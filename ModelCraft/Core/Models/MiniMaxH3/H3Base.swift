//
//  H3Base.swift
//  ModelCraft
//
//  Created by Hongshen on 27/8/26.
//


import Foundation
import Hub
import MLX

/// The composed MiniMax H3 Base model.
///
/// The tokenizer and 0.61 GB Audio VAE load with the model and stay resident.
/// The remaining components total roughly 143 GB while the largest single one
/// — the 66.7 GB text encoder — exceeds every memory tier this app targets, so a
/// render cannot hold those stages at once even on a 64 GiB machine. They load
/// on first use, and the two halves of ``H3RuntimeProfile`` decide how much of
/// each stage is read at once and whether a finished stage hands its weights
/// back before the next one starts.
///
/// The release only reclaims memory if nothing else still references the stage.
/// Each private stage helper below is written so that a releasable encoder or
/// decoder stays a local of that helper, which dies before the caller runs the
/// matching `release…Stage()`. Holding one of those components in a caller local
/// across the release would keep tens of gigabytes alive and turn the release
/// into a no-op.
///
/// Residency is mutable state on a `@unchecked Sendable` class: two concurrent
/// renders sharing one instance would release each other's stages mid-flight.
/// ``H3ModelFactory`` caches one instance per task, so a caller must not start a
/// second render against a model that is already generating.
public final class H3Base: @unchecked Sendable {
    private static let referenceVideoSampleFPS = 2.0
    private static let referenceVideoTemporalPatch = 2
    private static let referenceEncodeSeed: UInt64 = 42

    /// The task's own configuration, and with it the machine's residency tier:
    /// every component read and every stage release reads
    /// ``H3Configuration/runtimeProfile`` from here rather than carrying a second
    /// copy — see ``H3RuntimeProfile``.
    let configuration: H3Configuration
    let scheduler: H3Scheduler

    private let hub: HubApi

    private let tokenizer: H3Tokenizer
    private var encoder: H3Encoder?
    private var visualVAE: H3VisualVAE?
    private let audioVAE: H3AudioVAE
    private var omniTransformer: H3OmniTransformer?

    public init(hub: HubApi, configuration: H3Configuration) throws {
        self.hub = hub
        self.configuration = configuration
        self.scheduler = H3Scheduler(shift: configuration.videoSigmaShift)
        self.tokenizer = try H3Loader.loadTokenizer(hub: hub, configuration: configuration)
        self.audioVAE = try H3Loader.loadAudioVAE(hub: hub, configuration: configuration)
    }

    /// Clears MLX's free-buffer pool only after the stage's weights have been
    /// dropped, so the reclaimed buffers are actually back in the pool by then.
    private func releaseTextStage() {
        guard configuration.runtimeProfile.releasesComponentsBetweenStages else { return }
        encoder = nil
        Memory.clearCache()
    }

    private func releaseReferenceEncodingBuffers() {
        guard configuration.runtimeProfile.releasesComponentsBetweenStages else { return }
        Memory.clearCache()
    }

    private func releaseTransformerStage() {
        guard configuration.runtimeProfile.releasesComponentsBetweenStages else { return }
        omniTransformer = nil
        Memory.clearCache()
    }

    private func releaseVAEStage() {
        guard configuration.runtimeProfile.releasesComponentsBetweenStages else { return }
        visualVAE = nil
        Memory.clearCache()
    }

    /// Drops every releasable component before the factory evicts this task.
    /// The resident tokenizer and Audio VAE are released with the instance.
    public func cleanup() {
        encoder = nil
        visualVAE = nil
        omniTransformer = nil
        Memory.clearCache()
    }

    // MARK: - Generation

    @discardableResult
    public func generate(request: H3EvaluatorRequest) async throws -> H3EvaluatorResult {
        if Task.isCancelled { throw CancellationError() }

        let width = configuration.outputWidth
        let height = configuration.outputHeight
        let geometry = H3LatentGeometry(
            width: width,
            height: height,
            length: request.duration * configuration.frameRate,
            configuration: configuration)

        let seed = request.seed ?? UInt64.random(in: UInt64.min ... UInt64.max)

        // The text stage is the largest component in the pipeline and is never
        // read again after this call, so it always gives its memory back.
        let conditioning = try encodeText(for: request, geometry: geometry)
        releaseTextStage()
        if Task.isCancelled { throw CancellationError() }

        let conditions = try encodeReferences(for: request, geometry: geometry, seed: seed)
        releaseReferenceEncodingBuffers()
        if Task.isCancelled { throw CancellationError() }

        let sampled = try sample(
            geometry: geometry,
            conditioning: conditioning,
            conditions: conditions,
            steps: request.steps,
            seed: seed)
        // The latents are what the decoders below need; the Transformer is not.
        releaseTransformerStage()
        if Task.isCancelled { throw CancellationError() }

        let waveform = try decodeAudio(sampled.audio)
        if Task.isCancelled { throw CancellationError() }

        let frames = try decodeVideo(sampled.video)
        // Visual VAE and Audio VAE remain owned together through both decodes.
        releaseVAEStage()
        if Task.isCancelled { throw CancellationError() }

        return try await H3IO.save(
            frames: frames,
            waveform: waveform,
            to: request.videoOutput,
            fps: Double(configuration.frameRate),
            sampleRate: configuration.audioSampleRate)
    }

    // MARK: - Stages

    /// Encodes the prompt and any semantic image/video reference tokens.
    /// H3 Base owns and coordinates its encoder and tokenizer; callers provide
    /// only the generation input.
    private func encodeText(
        for request: H3EvaluatorRequest,
        geometry: H3LatentGeometry
    ) throws -> H3TextConditioningData {
        let encoder = try self.encoder
            ?? H3Loader.loadEncoder(hub: hub, configuration: configuration)
        self.encoder = encoder
        let presentationTokens = tokenizer.presentationTokens

        switch configuration.task {
        case .fl2va:
            let images = request.resolvedKeyframes(frameCount: geometry.frameCount).map(\.image)
            let encoded: (conditioning: MLXArray, tags: [Int])
            if images.isEmpty {
                let prompt = tokenizer.encodePrompt(request.prompt)
                encoded = (
                    try encoder.encodeText(ids: prompt.ids),
                    prompt.tags)
            } else {
                var elements: [H3Presentation.Element] = []
                for (index, image) in images.enumerated() {
                    let size = try H3IO.imageSize(at: image.path)
                    let (width, height, _) = H3VisionPreprocess.imageGrid(
                        width: size.width,
                        height: size.height)
                    let pixels = try H3IO.imageHWC(
                        at: image.path,
                        width: width,
                        height: height)
                    let (block, grid) = try encoder.encodeVisual(pixels: pixels)
                    elements.append(.tokens(tokenizer.encode("<Picture \(index + 1)>: ")))
                    elements.append(.vision(block, grid))
                }
                elements.append(.tokens(tokenizer.encode(request.prompt)))
                encoded = try encoder.encodeText(H3Presentation(
                    elements: elements,
                    visionStartToken: presentationTokens.visionStart,
                    visionEndToken: presentationTokens.visionEnd,
                    padToken: presentationTokens.pad))
            }

            eval(encoded.conditioning)
            return H3TextConditioningData(
                textEmbeddings: encoded.conditioning,
                tags: encoded.tags)

        case .ref2va:
            var elements: [H3Presentation.Element] = []
            var pictureIndex = 0
            var videoIndex = 0
            var audioIndex = 0

            for reference in request.references {
                switch try H3IO.decode(reference) {
                case .image(let image):
                    pictureIndex += 1
                    let (block, grid) = try encoder.encodeVisual(pixels: image.encoderPixels)
                    elements.append(.tokens(tokenizer.encode("<Picture \(pictureIndex)>: ")))
                    elements.append(.vision(block, grid))

                case .audio:
                    audioIndex += 1
                    elements.append(.tokens(tokenizer.encode("<Audio \(audioIndex)>: ")))

                case .video(let video):
                    if video.audio != nil {
                        audioIndex += 1
                        elements.append(.tokens(tokenizer.encode("<Audio \(audioIndex)>: ")))
                    }

                    videoIndex += 1
                    elements.append(.tokens(tokenizer.encode("<Video \(videoIndex)>: ")))
                    let sampled = try sampledVideoFrames(video.frames)
                    let encoded = try encoder.encodeVideo(frames: sampled.frames)
                    for (blockIndex, group) in encoded.enumerated() {
                        elements.append(.tokens(tokenizer.encode(
                            "<\(timestamp(sampled.blockTimestamps[blockIndex])) seconds>")))
                        elements.append(.vision(group.block, group.grid))
                    }
                }
            }

            elements.append(.tokens(tokenizer.encode(request.prompt)))
            let encoded = try encoder.encodeText(H3Presentation(
                elements: elements,
                visionStartToken: presentationTokens.visionStart,
                visionEndToken: presentationTokens.visionEnd,
                padToken: presentationTokens.pad))
            eval(encoded.conditioning)
            return H3TextConditioningData(
                textEmbeddings: encoded.conditioning,
                tags: encoded.tags)
        }
    }

    /// Encodes first/last frames or ordered Ref2VA media. H3 Base keeps the
    /// optional Visual VAE and resident Audio VAE, and coordinates both
    /// when a reference render needs them.
    private func encodeReferences(
        for request: H3EvaluatorRequest,
        geometry: H3LatentGeometry,
        seed: UInt64
    ) throws -> H3Conditions {
        let visualVAE = try self.visualVAE
            ?? H3Loader.loadVisualVAE(hub: hub, configuration: configuration)
        self.visualVAE = visualVAE

        switch configuration.task {
        case .fl2va:
            let keyframes = request.resolvedKeyframes(frameCount: geometry.frameCount)
            let visualLatents = try keyframes.map { keyframe in
                let pixels = try H3IO.image(
                    at: keyframe.image.path,
                    fit: (configuration.outputWidth, configuration.outputHeight))
                let latent = try visualVAE.encode(pixels)
                eval(latent)
                return latent
            }
            let anchors = keyframes.map {
                KeyframeConfig(resolvedFrameIndex: $0.frame)
            }
            return H3Conditions(
                videoRows: visualRows(
                    visualLatents,
                    augmentation: configuration.visualConditionNoise,
                    seed: seed),
                audioRows: nil,
                keyframes: anchors,
                references: [])

        case .ref2va:
            var visualLatents: [MLXArray] = []
            var audioRows: [MLXArray] = []
            var blocks: [H3ReferenceSequenceBlock] = []

            for reference in request.references {
                switch try H3IO.decode(reference) {
                case .image(let image):
                    let latent = try visualVAE.encode(
                        image.visualVAEPixels,
                        seed: Self.referenceEncodeSeed)
                    eval(latent)
                    visualLatents.append(latent)
                    blocks.append(H3ReferenceSequenceBlock(
                        kind: .image,
                        visual: referenceGeometry(of: latent)))

                case .audio(let audio):
                    let rows = try audioConditionRows(audio)
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
                    let latent = try visualVAE.encode(
                        pixels,
                        seed: Self.referenceEncodeSeed)
                    eval(latent)
                    visualLatents.append(latent)

                    let soundtrackRows = try video.audio.map {
                        try audioConditionRows($0)
                    }
                    if let soundtrackRows {
                        eval(soundtrackRows)
                        audioRows.append(soundtrackRows)
                    }
                    blocks.append(H3ReferenceSequenceBlock(
                        kind: .video,
                        visual: referenceGeometry(of: latent),
                        audioT: soundtrackRows.map { $0.dim(0) / 2 } ?? 0))
                }
            }

            return H3Conditions(
                videoRows: visualRows(
                    visualLatents,
                    augmentation: configuration.visualConditionNoise,
                    seed: seed),
                audioRows: audioRows.isEmpty ? nil : concatenated(audioRows, axis: 0),
                keyframes: [],
                references: blocks)
        }
    }

    private func visualRows(
        _ latents: [MLXArray],
        augmentation: Float,
        seed: UInt64
    ) -> MLXArray? {
        guard !latents.isEmpty else { return nil }
        let packed = latents.map {
            H3Packing.patchifyVideo($0.asType(.float32), patch: [1, 2, 2])
        }
        guard augmentation < 1.0 else {
            return concatenated(packed, axis: 0)
        }

        let mixed = packed.enumerated().map { index, condition in
            let noise = MLXRandom.normal(
                condition.shape,
                key: MLXRandom.key(seed &+ UInt64(index)))
            return MLXArray(augmentation) * condition
                + MLXArray(1.0 - augmentation) * noise
        }
        return concatenated(mixed, axis: 0)
    }

    private func sampledVideoFrames(
        _ frames: [MLXArray]
    ) throws -> (frames: [MLXArray], blockTimestamps: [Double]) {
        let sampleStride = Double(configuration.frameRate) / Self.referenceVideoSampleFPS
        var indices: [Int] = []
        var cursor = 0.0
        while Int(cursor.rounded()) < frames.count {
            let index = Int(cursor.rounded())
            if indices.last != index { indices.append(index) }
            cursor += sampleStride
        }
        guard indices.count >= Self.referenceVideoTemporalPatch else {
            throw H3EvaluatorError.invalidRequest(
                rule: "reference video is too short for the H3 Encoder",
                detail: "\(frames.count) normalized frame(s)",
                remedy: "provide at least two frames at the 2 fps reference sampling rate.")
        }

        var timestamps = indices.indices.map { Double($0) / Self.referenceVideoSampleFPS }
        while timestamps.count % Self.referenceVideoTemporalPatch != 0 {
            timestamps.append(timestamps.last!)
        }
        let blocks = Swift.stride(
            from: 0,
            to: timestamps.count,
            by: Self.referenceVideoTemporalPatch
        ).map {
            (timestamps[$0] + timestamps[$0 + Self.referenceVideoTemporalPatch - 1]) / 2.0
        }
        return (indices.map { frames[$0] }, blocks)
    }

    private func timestamp(_ seconds: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), seconds)
    }

    private func audioConditionRows(_ audio: H3DecodedAudio) throws -> MLXArray {
        let length = min(audio.samples[0].count, audio.samples[1].count)
        let samples = audio.samples.flatMap { Array($0.prefix(length)) }
        let waveform = MLXArray(samples, [1, 2, length])
        return try H3Packing.packAudio(audioVAE.encode(waveform))
    }

    private func referenceGeometry(
        of latent: MLXArray
    ) -> H3ReferenceSequenceBlock.VisualGeometry {
        H3ReferenceSequenceBlock.VisualGeometry(
            latentT: latent.dim(2),
            latentH: latent.dim(3),
            latentW: latent.dim(4))
    }

    /// Ref2VA snaps video references down to the VAE's `17n+5` lattice.
    private func alignedReferenceFrameCount(_ count: Int) -> Int {
        max(1, (count - 5) / 17) * 17 + 5
    }

    /// Runs the whole denoise loop. Loads the Transformer and leaves it
    /// resident; the caller releases it once sampling is done.
    private func sample(
        geometry: H3LatentGeometry,
        conditioning: H3TextConditioningData,
        conditions: H3Conditions,
        steps: Int,
        seed: UInt64
    ) throws -> H3Sampler.Output {
        let model = try omniTransformer ?? H3OmniTransformer(
            config: configuration,
            hub: hub,
            configuration: configuration)
        omniTransformer = model
        return try H3Sampler().sample(
            model: model,
            steps: steps,
            seed: seed,
            geometry: geometry,
            conditioning: conditioning,
            conditions: conditions,
            scheduler: scheduler)
    }

    private func decodeAudio(_ latent: MLXArray) throws -> MLXArray {
        let waveform = try audioVAE.decode(latent)
        eval(waveform)
        return waveform
    }

    private func decodeVideo(_ latent: MLXArray) throws -> MLXArray {
        let vae = try visualVAE
            ?? H3Loader.loadVisualVAE(hub: hub, configuration: configuration)
        visualVAE = vae
        let frames = try vae.decode(latent)
        eval(frames)
        return frames
    }

}

// MARK: - Latent and sequence layout

extension H3LatentGeometry {
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

/// The packed sequence a DiT block actually sees.
///
/// **Order is text | visual conditions | audio | video** — target audio then
/// target video, always the last two segments.
///
/// **There is no batch dimension inside the stack.** Blocks operate on
/// `[S, hidden]`, and slices come from the segment table.
extension H3Sequence {
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
