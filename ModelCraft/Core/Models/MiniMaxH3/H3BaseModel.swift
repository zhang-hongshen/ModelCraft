// SPDX-License-Identifier: Apache-2.0

import Foundation
import Hub
import MLX

public final class H3BaseModel: @unchecked Sendable {
    private let hub: HubApi
    private let configuration: H3Configuration

    public init(hub: HubApi, configuration: H3Configuration) {
        self.hub = hub
        self.configuration = configuration
    }

    @discardableResult
    public func generate(
        request: H3EvaluatorRequest,
        progress: (H3EvaluatorProgress) -> Void = { _ in },
        cancellation: H3EvaluatorCancellation? = nil,
        log: (String) -> Void = { _ in }
    ) async throws -> H3EvaluatorResult {
        try request.validate(for: configuration.task)
        try checkCancellation(cancellation, phase: .textConditioning, detail: "before loading")

        let started = Date()
        func mark(
            _ phase: H3EvaluatorProgress.Phase,
            _ detail: String,
            completed: Int = 0,
            total: Int = 0
        ) {
            progress(H3EvaluatorProgress(
                phase: phase,
                completed: completed,
                total: total,
                detail: detail,
                elapsed: Date().timeIntervalSince(started)))
        }

        let (width, height) = try request.dimensions()
        let geometry = H3LatentGeometry(
            width: width,
            height: height,
            length: request.durationSeconds * configuration.frameRate,
            configuration: configuration)

        let conditioning: H3TextConditioningData
        let conditions: H3Conditions
        switch configuration.task {
        case .fl2va:
            mark(.textConditioning, "loading H3 Encoder for FL2VA")
            conditioning = try H3TextConditioning.encodeFL2VA(
                prompt: request.prompt,
                request: request,
                hub: hub,
                configuration: configuration,
                log: log)
            Memory.clearCache()
            try checkCancellation(cancellation, phase: .textConditioning, detail: "after encoding")

            mark(.conditionEncoding, "encoding FL2VA keyframes with H3 Visual VAE")
            let visualLatents = try H3Conditioning.encodeFL2VAVisual(
                request: request,
                hub: hub,
                configuration: configuration,
                width: width,
                height: height,
                frameCount: geometry.frameCount,
                log: log)
            conditions = try H3Conditioning.assembleFL2VA(
                request: request,
                geometry: geometry,
                visualLatents: visualLatents,
                log: log)

        case .ref2va:
            mark(.textConditioning, "loading H3 Encoder for Ref2VA")
            conditioning = try H3Ref2VAConditioning.encodeText(
                prompt: request.prompt,
                references: request.references,
                hub: hub,
                configuration: configuration,
                log: log)
            Memory.clearCache()
            try checkCancellation(cancellation, phase: .textConditioning, detail: "after encoding")

            mark(.conditionEncoding, "encoding ordered Ref2VA references")
            conditions = try H3Ref2VAConditioning.encodeReferences(
                request: request,
                hub: hub,
                configuration: configuration,
                log: log)
        }
        Memory.clearCache()
        try checkCancellation(cancellation, phase: .conditionEncoding, detail: "before Transformer")

        mark(.modelLoading, "loading \(configuration.modelName) Transformer")
        let transformer = try H3OmniTransformer(
            weights: try H3BaseWeights(
                hub: hub,
                configuration: configuration,
                key: "transformerWeights"),
            computeDType: .bfloat16,
            backend: SDPABackend())

        mark(.sampling, "sampling \(configuration.modelName)", completed: 0, total: request.steps)
        let sampled = try H3Sampling.run(
            model: transformer,
            request: request,
            geometry: geometry,
            conditioning: conditioning,
            conditions: conditions,
            cancellation: cancellation,
            onStep: { completed, total in
                mark(
                    .sampling,
                    "step \(completed) of \(total)",
                    completed: completed,
                    total: total)
            })
        try checkCancellation(cancellation, phase: .sampling, detail: "after sampling")

        mark(.decoding, "decoding Audio VAE")
        let audioVAE = try H3AudioVAE(hub: hub, configuration: configuration)
        let waveform = audioVAE.decode(sampled.audio)
        eval(waveform)
        try checkCancellation(cancellation, phase: .decoding, detail: "after audio decode")

        mark(.decoding, "decoding Visual VAE")
        let videoVAE = try H3VisualVAE(hub: hub, configuration: configuration)
        let frames = videoVAE.decode(sampled.video)
        eval(frames)
        try checkCancellation(cancellation, phase: .decoding, detail: "after video decode")

        mark(.writing, "writing video")
        return try await write(frames: frames, waveform: waveform, request: request, log: log)
    }

    private func write(
        frames: MLXArray,
        waveform: MLXArray,
        request: H3EvaluatorRequest,
        log: (String) -> Void
    ) async throws -> H3EvaluatorResult {
        let samples = deinterleave(waveform)
        if let audioURL = request.audioOutput {
            try H3IO.writeWAV(samples: samples, to: audioURL)
        }

        let frameCount = frames.dim(2)
        let frameHeight = frames.dim(3)
        let frameWidth = frames.dim(4)
        let rgb = clip((frames + 1.0) * 127.5, min: 0.0, max: 255.0)
            .transposed(0, 2, 3, 4, 1)
            .reshaped([frameCount, frameHeight, frameWidth, 3])
        let alpha = MLXArray.full(
            [frameCount, frameHeight, frameWidth, 1],
            values: MLXArray(255.0 as Float))
        let argb = concatenated([alpha, rgb], axis: -1).asType(.uint8)
        eval(argb)

        var muxedAudio = true
        do {
            try await H3IO.writeMovie(
                argb: argb,
                waveform: samples,
                to: request.videoOutput,
                fps: Double(configuration.frameRate),
                sampleRate: configuration.audioSampleRate)
        } catch {
            muxedAudio = false
            log("audio muxing failed; writing a video-only MP4: \(error)")
            try await H3IO.writeMovie(
                argb: argb,
                waveform: samples,
                to: request.videoOutput,
                fps: Double(configuration.frameRate),
                sampleRate: configuration.audioSampleRate,
                withAudio: false)
        }

        return H3EvaluatorResult(
            video: request.videoOutput,
            audio: request.audioOutput,
            frameCount: frameCount,
            width: frameWidth,
            height: frameHeight,
            seconds: Double(frameCount) / Double(configuration.frameRate),
            muxedAudio: muxedAudio)
    }

    private func checkCancellation(
        _ cancellation: H3EvaluatorCancellation?,
        phase: H3EvaluatorProgress.Phase,
        detail: String
    ) throws {
        if Task.isCancelled || cancellation?.isCancelled == true {
            throw H3EvaluatorCancelled(phase: phase, detail: detail)
        }
    }

    private func deinterleave(_ waveform: MLXArray) -> [[Float]] {
        let length = waveform.dim(2)
        let flat = waveform
            .reshaped([waveform.dim(0) * waveform.dim(1), length])
            .asType(.float32)
            .asArray(Float.self)
        return (0 ..< min(2, waveform.dim(1))).map {
            Array(flat[($0 * length) ..< (($0 + 1) * length)])
        }
    }
}
