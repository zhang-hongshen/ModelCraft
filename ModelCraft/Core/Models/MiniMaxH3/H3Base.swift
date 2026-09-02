//
//  H3AudioVAE.swift
//  ModelCraft
//
//  Created by Hongshen on 27/8/26.
//

import Foundation
import Hub
import MLX

/// The composed MiniMax H3 Base model.
///
/// Like ``StableDiffusion``, this type is the component graph rather than a
/// second pipeline abstraction: it owns the tokenizer, H3 text/vision encoder,
/// both VAE directions, the shared Omni Transformer and the sampler schedule.
/// ``generate(request:)`` only connects those
/// components for one request.
public final class H3Base: @unchecked Sendable {
    let configuration: H3Configuration
    let tokenizer: H3Tokenizer
    let encoder: H3Encoder
    let visualVAEEncoder: H3VisualVAEEncoder
    let visualVAE: H3VisualVAE
    let audioVAEEncoder: H3AudioVAEEncoder
    let audioVAE: H3AudioVAE
    let omniTransformer: H3OmniTransformer
    let scheduler: H3Scheduler

    public init(hub: HubApi, configuration: H3Configuration) throws {
        self.configuration = configuration

        self.tokenizer = try H3Tokenizer(hub: hub, configuration: configuration)
        self.encoder = try H3Encoder(hub: hub, configuration: configuration)

        let visualVAEWeights = try H3Loader.loadWeights(
            hub: hub,
            configuration: configuration,
            key: .videoVAEWeights)
        self.visualVAEEncoder = try H3VisualVAEEncoder(weights: visualVAEWeights)
        self.visualVAE = try H3VisualVAE(weights: visualVAEWeights)

        let audioVAEWeights = try H3Loader.loadWeights(
            hub: hub,
            configuration: configuration,
            key: .audioVAEWeights)
        self.audioVAEEncoder = try H3AudioVAEEncoder(weights: audioVAEWeights)
        self.audioVAE = try H3AudioVAE(weights: audioVAEWeights)

        self.omniTransformer = try H3Loader.loadOmniTransformer(hub: hub, configuration: configuration)
        self.scheduler = H3Scheduler(shift: configuration.videoSigmaShift)
    }

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

        let conditioning: H3TextConditioningData
        let conditions: H3Conditions
        let seed = request.seed ?? UInt64.random(in: UInt64.min ... UInt64.max)
        switch configuration.task {
        case .fl2va:
            let keyframes = request.resolvedKeyframes(frameCount: geometry.frameCount)
            conditioning = try H3Conditioning.encodeFL2VA(
                prompt: request.prompt,
                keyframes: keyframes,
                encoder: encoder,
                tokenizer: tokenizer)
            Memory.clearCache()
            if Task.isCancelled { throw CancellationError() }
            let visualLatents = try H3Conditioning.encodeFL2VAVisual(
                keyframes: keyframes,
                encoder: visualVAEEncoder,
                width: width,
                height: height)
            conditions = try H3Conditioning.assembleFL2VA(
                keyframes: keyframes,
                geometry: geometry,
                visualLatents: visualLatents,
                seed: seed)

        case .ref2va:
            conditioning = try H3Conditioning.encodeText(
                prompt: request.prompt,
                references: request.references,
                encoder: encoder,
                tokenizer: tokenizer)
            Memory.clearCache()
            if Task.isCancelled { throw CancellationError() }
            conditions = try H3Conditioning.encodeReferences(
                references: request.references,
                visualEncoder: visualVAEEncoder,
                audioEncoder: audioVAEEncoder,
                configuration: configuration,
                seed: seed)
        }
        Memory.clearCache()
        if Task.isCancelled { throw CancellationError() }
        let sampled = try H3Sampler().sample(
            model: omniTransformer,
            steps: request.steps,
            seed: seed,
            geometry: geometry,
            conditioning: conditioning,
            conditions: conditions,
            scheduler: scheduler)
        if Task.isCancelled { throw CancellationError() }
        let waveform = audioVAE.decode(sampled.audio)
        eval(waveform)
        if Task.isCancelled { throw CancellationError() }

        let frames = visualVAE.decode(sampled.video)
        eval(frames)
        if Task.isCancelled { throw CancellationError() }

        return try await H3IO.save(
            frames: frames,
            waveform: waveform,
            to: request.videoOutput,
            fps: Double(configuration.frameRate),
            sampleRate: configuration.audioSampleRate)
    }
}
