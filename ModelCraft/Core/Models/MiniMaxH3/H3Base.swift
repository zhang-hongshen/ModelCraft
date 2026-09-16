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
/// **Nothing is loaded in `init`.** H3's four components total roughly 144 GB
/// while its largest single one — the 66.7 GB text encoder — exceeds every
/// memory tier this app targets, so a render cannot hold the pipeline at once
/// even on a 64 GiB machine. Components therefore load on first use, and the two
/// halves of ``H3RuntimeProfile`` decide how much of each stage is read at once
/// and whether a finished stage hands its weights back before the next one
/// starts.
///
/// The release only reclaims memory if nothing else still references the stage.
/// Each private stage helper below is written so that its encoder, tokenizer or
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
    /// The task's own configuration, and with it the machine's residency tier:
    /// every component read and every stage release reads
    /// ``H3Configuration/runtimeProfile`` from here rather than carrying a second
    /// copy — see ``H3RuntimeProfile``.
    let configuration: H3Configuration
    let scheduler: H3Scheduler

    private let hub: HubApi

    private var tokenizer: H3Tokenizer?
    private var encoder: H3Encoder?
    private var visualVAE: H3VisualVAE?
    private var audioVAE: H3AudioVAE?
    private var omniTransformer: H3OmniTransformer?

    public init(hub: HubApi, configuration: H3Configuration) {
        self.hub = hub
        self.configuration = configuration
        self.scheduler = H3Scheduler(shift: configuration.videoSigmaShift)
    }

    /// Clears MLX's free-buffer pool only after the stage's weights have been
    /// dropped, so the reclaimed buffers are actually back in the pool by then.
    private func releaseTextStage() {
        guard configuration.runtimeProfile.releasesComponentsBetweenStages else { return }
        encoder = nil
        tokenizer = nil
        Memory.clearCache()
    }

    private func releaseVisualEncoderStage() {
        guard configuration.runtimeProfile.releasesComponentsBetweenStages else { return }
        Memory.clearCache()
    }

    private func releaseAudioEncoderStage() {
        guard configuration.runtimeProfile.releasesComponentsBetweenStages else { return }
        Memory.clearCache()
    }

    private func releaseTransformerStage() {
        guard configuration.runtimeProfile.releasesComponentsBetweenStages else { return }
        omniTransformer = nil
        Memory.clearCache()
    }

    private func releaseAudioVAEStage() {
        guard configuration.runtimeProfile.releasesComponentsBetweenStages else { return }
        audioVAE = nil
        Memory.clearCache()
    }

    private func releaseVisualVAEStage() {
        guard configuration.runtimeProfile.releasesComponentsBetweenStages else { return }
        visualVAE = nil
        Memory.clearCache()
    }

    /// Drops every component. Generation releases stage by stage as it goes;
    /// this is for the factory when it evicts a task outright.
    public func cleanup() {
        tokenizer = nil
        encoder = nil
        visualVAE = nil
        audioVAE = nil
        omniTransformer = nil
        Memory.clearCache()
    }

    // MARK: - Stages

    /// Prompt conditioning. Both tasks need the text encoder and differ only in
    /// how keyframes or references fold into the text span.
    ///
    /// Loads the text stage and leaves it resident; the caller releases it.
    private func textConditioning(
        for request: H3EvaluatorRequest,
        geometry: H3LatentGeometry
    ) throws -> H3TextConditioningData {
        let encoder = try self.encoder
            ?? H3Loader.loadEncoder(hub: hub, configuration: configuration)
        let tokenizer = try self.tokenizer
            ?? H3Loader.loadTokenizer(hub: hub, configuration: configuration)
        self.encoder = encoder
        self.tokenizer = tokenizer

        switch configuration.task {
        case .fl2va:
            return try H3Conditioning.encodeFL2VA(
                prompt: request.prompt,
                keyframes: request.resolvedKeyframes(frameCount: geometry.frameCount),
                encoder: encoder,
                tokenizer: tokenizer)
        case .ref2va:
            return try H3Conditioning.encodeText(
                prompt: request.prompt,
                references: request.references,
                encoder: encoder,
                tokenizer: tokenizer)
        }
    }

    /// The task's non-text conditioning rows. FL2VA encodes first/last frames
    /// through the video VAE; Ref2VA encodes ordered references through the
    /// vision tower and both VAE encoders.
    ///
    /// Loads the encoders it needs and leaves them resident; the caller releases.
    private func conditioningRows(
        for request: H3EvaluatorRequest,
        geometry: H3LatentGeometry,
        seed: UInt64
    ) throws -> H3Conditions {
        // Both tasks read the references' pixels through the video VAE's encoder;
        // only a reference render reaches the audio one.
        let vae = try visualVAE
            ?? H3Loader.loadVisualVAE(hub: hub, configuration: configuration)
        visualVAE = vae

        switch configuration.task {
        case .fl2va:
            let keyframes = request.resolvedKeyframes(frameCount: geometry.frameCount)
            let visualLatents = try H3Conditioning.encodeFL2VAVisual(
                keyframes: keyframes,
                vae: vae,
                width: configuration.outputWidth,
                height: configuration.outputHeight)
            return try H3Conditioning.assembleFL2VA(
                keyframes: keyframes,
                geometry: geometry,
                visualLatents: visualLatents,
                seed: seed)

        case .ref2va:
            let audioVae = try audioVAE
                ?? H3Loader.loadAudioVAE(hub: hub, configuration: configuration)
            self.audioVAE = audioVae
            return try H3Conditioning.encodeReferences(
                references: request.references,
                vae: vae,
                audioVae: audioVae,
                configuration: configuration,
                seed: seed)
        }
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
        let model = try omniTransformer ?? H3Loader.loadOmniTransformer(
            hub: hub, configuration: configuration)
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
        let vae = try audioVAE
            ?? H3Loader.loadAudioVAE(hub: hub, configuration: configuration)
        audioVAE = vae
        let waveform = try vae.decode(latent)
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
        let conditioning = try textConditioning(for: request, geometry: geometry)
        releaseTextStage()
        if Task.isCancelled { throw CancellationError() }

        // VAE encoders are only needed to turn conditioning media into latents;
        // the decoders that come later are separate objects.
        let conditions = try conditioningRows(for: request, geometry: geometry, seed: seed)
        releaseVisualEncoderStage()
        releaseAudioEncoderStage()
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
        releaseAudioVAEStage()
        if Task.isCancelled { throw CancellationError() }

        let frames = try decodeVideo(sampled.video)
        releaseVisualVAEStage()
        if Task.isCancelled { throw CancellationError() }

        return try await H3IO.save(
            frames: frames,
            waveform: waveform,
            to: request.videoOutput,
            fps: Double(configuration.frameRate),
            sampleRate: configuration.audioSampleRate)
    }
}
