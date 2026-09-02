//
//  H3Sampler.swift
//  ModelCraft
//
//  Created by Hongshen on 27/8/26.
//

import Foundation
import MLX

struct H3Scheduler: Sendable {
    let shift: Double
    init(shift: Double = H3Configuration.presetH3BaseFL2VA.videoSigmaShift) { self.shift = shift }

    func sigma(t: Double) -> Double {
        shift * t / (1.0 + (shift - 1.0) * t)
    }

    /// `steps + 1` values, from 1.0 down to exactly 0.0.
    func sigmas(steps: Int) -> [Double] {
        precondition(steps > 0, "steps must be positive")
        return (0...steps).map { i in
            i == steps ? 0.0 : sigma(t: 1.0 - Double(i) / Double(steps))
        }
    }
}

/// Mapping one stream's sigma onto another stream's shifted schedule.
///
/// The sampler only ever sees the **video** sigma. The audio stream runs on
/// shift 3 while video runs on shift 12, so the DiT maps the video sigma back
/// to the unshifted grid and re-applies the audio shift in closed form. The two
/// streams therefore denoise at genuinely different rates inside a single
/// forward pass — this is the reason there is a timestep row at all.
enum SigmaMap {
    /// Invert `sigma = s*b/(1+(s-1)*b)` to the base grid, re-apply `to`.
    static func shift(_ sigma: Float, from: Float, to: Float) -> Float {
        let base = sigma / (from + sigma * (1.0 - from))
        return to * base / (1.0 + (to - 1.0) * base)
    }

    /// `d(sigma_to)/d(sigma_from)` at the same base-grid point.
    ///
    /// The sampler integrates the flat ODE `dX/dsigma_v = (X - denoised)/sigma_v`
    /// for both streams. Scaling the audio velocity by this slope is what makes
    /// that shared ODE equal the audio stream's true ODE on its own schedule.
    /// Drop it and audio drifts out of step with video over the sampling run.
    static func slope(_ sigma: Float, from: Float, to: Float) -> Float {
        let base = sigma / (from + sigma * (1.0 - from))
        let num = to * pow(1.0 + (from - 1.0) * base, 2)
        let den = from * pow(1.0 + (to - 1.0) * base, 2)
        return num / den
    }
}

/// Which AdaLN timestep row each stream uses for one forward pass.
///
/// The distinct timesteps form a sorted set and AdaLN indexes rows by their
/// position in that set. When video and audio share a timestep, both streams
/// use the same row.
///
/// Arithmetic is float32 on purpose: the reference derives these from an fp32
/// sigma tensor, and the deduplication is exact equality on those fp32 values.
struct TimestepPlan: Sendable, Equatable {
    /// Distinct timestep values, ascending — the rows of `t_emb`.
    let values: [Float]
    private let segRowMap: [H3SequenceSegmentKind: Int]
    /// `d(sigma_a)/d(sigma_v)`, which the audio velocity must be scaled by.
    let audioSlope: Float
    /// The video sigma this plan was built from, retained rather than recovered.
    /// `values` holds timesteps, and several distinct sigmas map to the same
    /// deduplicated timestep set, so the plan cannot be run backwards to the
    /// sigma that produced it.
    let sigmaVideo: Float

    init(sigmaVideo: Double,
                segments: [H3SequenceSegment] = [],
                visualCondNoiseAug: Float = 0.999,
                shiftVideo: Double = H3Configuration.presetH3BaseFL2VA.videoSigmaShift,
                shiftAudio: Double = H3Configuration.presetH3BaseFL2VA.audioSigmaShift) {
        let sv = max(Float(sigmaVideo), 1e-6)
        let fv = Float(shiftVideo), fa = Float(shiftAudio)
        let tv = 1.0 - sv
        let ta = 1.0 - SigmaMap.shift(sv, from: fv, to: fa)

        let actualSegments = segments.isEmpty ? [
            H3SequenceSegment(start: 0, stop: 1, kind: .text),
            H3SequenceSegment(start: 1, stop: 2, kind: .audio),
            H3SequenceSegment(start: 2, stop: 3, kind: .video)
        ] : segments

        let hasVisualCondition = actualSegments.contains { $0.kind == .visualCondition }
        let hasAudioCondition = actualSegments.contains { $0.kind == .audioCondition }

        let tCond = max(tv, visualCondNoiseAug)

        var uniqueSet = Set<Float>([tv, ta])
        if hasVisualCondition { uniqueSet.insert(tCond) }
        if hasAudioCondition { uniqueSet.insert(1.0) }

        let sortedUnique = uniqueSet.sorted()
        self.values = sortedUnique

        var rowMap: [H3SequenceSegmentKind: Int] = [:]
        rowMap[.text] = sortedUnique.firstIndex(of: tv)!
        rowMap[.video] = sortedUnique.firstIndex(of: tv)!
        rowMap[.audio] = sortedUnique.firstIndex(of: ta)!
        rowMap[.visualCondition] = sortedUnique.firstIndex(of: tCond)
            ?? sortedUnique.firstIndex(of: tv)!
        rowMap[.audioCondition] = sortedUnique.firstIndex(of: 1.0)
            ?? sortedUnique.firstIndex(of: ta)!

        self.segRowMap = rowMap
        self.audioSlope = SigmaMap.slope(sv, from: fv, to: fa)
        self.sigmaVideo = sv
    }

    func row(for kind: H3SequenceSegmentKind) -> Int {
        segRowMap[kind]!
    }

    var videoRow: Int { row(for: .video) }
    var audioRow: Int { row(for: .audio) }
}


final class H3Sampler {
    private var oldSigmaDown: Float? = nil
    private var oldDenoised: MLXArray? = nil

    struct Output {
        let video: MLXArray
        let audio: MLXArray
    }

    init() {}

    /// Runs the complete H3 flow-matching loop for the video and audio streams.
    /// Each stream gets its own step history because the multistep integrator
    /// must not mix denoised values from different latent spaces.
    func sample(
        model: H3OmniTransformer,
        steps: Int,
        seed: UInt64,
        geometry: H3LatentGeometry,
        conditioning: H3TextConditioningData,
        conditions: H3Conditions,
        scheduler: H3Scheduler
    ) throws -> Output {
        MLXRandom.seed(seed)
        var currentVideo = MLXRandom.normal(geometry.videoLatentShape())
        var currentAudio = MLXRandom.normal(geometry.audioLatentShape())

        let sigmas = scheduler.sigmas(steps: steps)
        let layout: H3Sequence
        if conditions.references.isEmpty {
            layout = try H3Sequence(
                textTokens: conditioning.textEmbeddings.dim(1),
                geometry: geometry,
                keyframes: conditions.keyframes)
        } else {
            layout = try H3Sequence(
                textTokens: conditioning.textEmbeddings.dim(1),
                geometry: geometry,
                references: conditions.references)
        }
        let renderState = try model.prepareRender(
            textEmbeddings: conditioning.textEmbeddings,
            layout: layout)
        let videoSampler = H3Sampler()
        let audioSampler = H3Sampler()

        for index in 0 ..< steps {
            if Task.isCancelled { throw CancellationError() }
            let sigma = Float(sigmas[index])
            let sigmaNext = Float(sigmas[index + 1])
            let previousSigma = index > 0 ? Float(sigmas[index - 1]) : nil
            let velocity = try model.velocity(
                videoLatent: currentVideo,
                audioLatent: currentAudio,
                textEmbeddings: conditioning.textEmbeddings,
                sigmaVideo: Double(sigma),
                geometry: geometry,
                textTags: conditioning.tags,
                condVideo: conditions.videoRows,
                condAudio: conditions.audioRows,
                renderState: renderState)

            let videoDenoised = currentVideo - velocity.video * MLXArray(sigma)
            let audioDenoised = currentAudio - velocity.audio * MLXArray(sigma)
            currentVideo = videoSampler.step(
                x: currentVideo,
                denoised: videoDenoised,
                sigma: sigma,
                sigmaNext: sigmaNext,
                prevSigma: previousSigma)
            currentAudio = audioSampler.step(
                x: currentAudio,
                denoised: audioDenoised,
                sigma: sigma,
                sigmaNext: sigmaNext,
                prevSigma: previousSigma)
            eval(currentVideo, currentAudio)
        }

        return Output(video: currentVideo, audio: currentAudio)
    }

    /// Advance one step of the res_multistep ODE integration.
    private func step(
        x: MLXArray,
        denoised: MLXArray,
        sigma: Float,
        sigmaNext: Float,
        prevSigma: Float?
    ) -> MLXArray {
        let sigmaDown = sigmaNext

        let tFn = { (s: Float) -> Float in -log(s) }
        let phi1Fn = { (t: Float) -> Float in
            if abs(t) < 1e-6 {
                return 1.0 + t / 2.0
            }
            return (exp(t) - 1.0) / t
        }
        let phi2Fn = { (t: Float) -> Float in
            if abs(t) < 1e-6 {
                return 0.5 + t / 6.0
            }
            return (phi1Fn(t) - 1.0) / t
        }

        var nextX = x
        if sigmaDown == 0 || oldDenoised == nil {
            // Euler step
            let d = (x - denoised) / sigma
            let dt = sigmaDown - sigma
            nextX = x + d * dt
        } else {
            // Second order multistep method
            let t = tFn(sigma)
            let tOld = tFn(oldSigmaDown!)
            let tNext = tFn(sigmaDown)
            let tPrev = tFn(prevSigma!)

            let h = tNext - t
            let c2 = (tPrev - tOld) / h

            let phi1Val = phi1Fn(-h)
            let phi2Val = phi2Fn(-h)

            var b1 = phi1Val - phi2Val / c2
            var b2 = phi2Val / c2

            if b1.isNaN { b1 = 0.0 }
            if b2.isNaN { b2 = 0.0 }

            let decay = sigmaDown / sigma
            nextX = MLXArray(decay) * x + MLXArray(h) * (MLXArray(b1) * denoised + MLXArray(b2) * oldDenoised!)
        }

        self.oldDenoised = denoised
        self.oldSigmaDown = sigmaDown

        return nextX
    }
}
