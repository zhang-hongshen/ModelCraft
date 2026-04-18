//
//  STTService.swift
//  ModelCraft
//
//  Created by Hongshen on 6/4/26.
//

import Observation
import Foundation
import Combine
@preconcurrency import AVFAudio

import MLXAudioSTT
import MLXAudioCore
import MLX

@MainActor
@Observable
class STTService {
    var isLoading = false
    var transcript: String = ""

    // Streaming parameters
    var streamingDelayMs: Int = 480  // .agent default

    // Model configuration
    var modelId: String = "mlx-community/Qwen3-ASR-0.6B-4bit"

    // Recording state
    var isRecording: Bool { recorder.isRecording }
    var recordingDuration: TimeInterval { recorder.recordingDuration }
    var audioLevel: Float { recorder.audioLevel }

    private var model: Qwen3ASRModel?
    private let recorder = AudioRecorder()
    private var generationTask: Task<Void, Never>?

    init() {}

    func loadModel() async {
        guard model == nil else { return }

        isLoading = true

        do {
            model = try await Qwen3ASRModel.fromPretrained(modelId)
        } catch {
            print("Failed to load model: \(error.localizedDescription)")
        }

        isLoading = false
    }

    func reloadModel() async {
        model = nil
//        Memory.clearCache()
        await loadModel()
    }

    // MARK: - Live Recording & Streaming Transcription

    private var liveTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var streamingSession: StreamingInferenceSession?
    private var lastReadPos: Int = 0

    func startRecording() async {
        guard let model = model else {
            print("Model not loaded")
            return
        }

        transcript = ""
        lastReadPos = 0

        do {
            try await recorder.startRecording()
        } catch {
            print(error.localizedDescription)
            return
        }

        // Create streaming session
        let config = StreamingConfig(
            decodeIntervalSeconds: 1.0,
            maxCachedWindows: 60,
            delayPreset: .custom(ms: streamingDelayMs),
            maxTokensPerPass: 1024
        )
        let session = StreamingInferenceSession(model: model, config: config)
        streamingSession = session

        // Listen to events from the session
        eventTask = Task {
            for await event in session.events {
                switch event {
                case .displayUpdate(let confirmed, let provisional):
                    break
                case .confirmed(let text):
                    transcript = text
                    break
                case .provisional:
                    break
                case .stats(let stats):
                    break
                case .ended(let fullText):
                    transcript = fullText
                }
            }
            // Stream ended naturally — clean up
            streamingSession = nil
            eventTask = nil
        }

        // Audio feed loop: read new samples every 100ms and feed to session
        liveTask = Task {
            while !Task.isCancelled && recorder.isRecording {
                if let (audio, endPos) = recorder.getAudio(from: lastReadPos) {
                    lastReadPos = endPos
                    let samples = audio.asArray(Float.self)
                    session.feedAudio(samples: samples)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stopRecording() {
        liveTask?.cancel()
        liveTask = nil

        _ = recorder.stopRecording()

        // Feed any remaining audio, then stop session
        if let session = streamingSession {
            if let (audio, endPos) = recorder.getAudio(from: lastReadPos) {
                lastReadPos = endPos
                let samples = audio.asArray(Float.self)
                session.feedAudio(samples: samples)
            }

            // Stop promotes all provisional tokens and emits .ended
            // The eventTask will process .ended and clean up naturally
            session.stop()
        }
    }

    func cancelRecording() {
        liveTask?.cancel()
        liveTask = nil
        streamingSession?.cancel()
        streamingSession = nil
        eventTask?.cancel()
        eventTask = nil
        recorder.cancelRecording()
        lastReadPos = 0
    }

    func stop() {
        liveTask?.cancel()
        liveTask = nil
        streamingSession?.cancel()
        streamingSession = nil
        eventTask?.cancel()
        eventTask = nil
        generationTask?.cancel()
        generationTask = nil

        if isRecording {
            recorder.cancelRecording()
            lastReadPos = 0
        }
    }

    private func resampleAudio(_ audio: MLXArray, from sourceSR: Int, to targetSR: Int) throws -> MLXArray {
        let samples = audio.asArray(Float.self)

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sourceSR), channels: 1, interleaved: false
        ), let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(targetSR), channels: 1, interleaved: false
        ) else {
            throw NSError(domain: "STT", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio formats"])
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw NSError(domain: "STT", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter"])
        }

        let inputFrameCount = AVAudioFrameCount(samples.count)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrameCount) else {
            throw NSError(domain: "STT", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create input buffer"])
        }
        inputBuffer.frameLength = inputFrameCount
        memcpy(inputBuffer.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)

        let ratio = Double(targetSR) / Double(sourceSR)
        let outputFrameCount = AVAudioFrameCount(Double(samples.count) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
            throw NSError(domain: "STT", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create output buffer"])
        }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let error { throw error }

        let outputSamples = Array(UnsafeBufferPointer(
            start: outputBuffer.floatChannelData![0], count: Int(outputBuffer.frameLength)
        ))
        return MLXArray(outputSamples)
    }
}
