//
//  STTService.swift
//  ModelCraft
//
//  Created by Hongshen on 6/4/26.
//

import Observation
import Foundation

import MLXAudioSTT
import MLXAudioCore
import MLX
import HuggingFace

@MainActor
@Observable
final class STTService {

    enum State {
        case idle
        case loading
        case recording
        /// Recording stopped and the remaining audio is being transcribed.
        case transcribing
    }

    private(set) var state: State = .idle
    /// Read by the waveform at its display cadence; metering never gates capture.
    var level: Float { recorder.level }

    private let recognizer = VoiceRecognizer()
    private let recorder = AudioRecorder()
    private var isStopRequested = false

    init() {}

    /// Loads a Qwen3-ASR model from the shared cache, downloading it there when absent.
    nonisolated static func loadModel(id: String) async throws -> Qwen3ASRModel {
        try await HubCache.default.loadModel(
            id: id,
            matching: ["*.safetensors", "*.json", "*.txt"],
            using: Qwen3ASRModel.fromModelDirectory)
    }

    // MARK: - Recording

    /// Records until `stop()` is called, then transcribes the captured audio locally.
    func record() async throws -> String {
        isStopRequested = false
        state = .loading
        defer {
            recorder.stop()
            state = .idle
        }

        try Task.checkCancellation()
        try await recorder.start()
        try Task.checkCancellation()
        state = .recording
        while !isStopRequested {
            try await Task.sleep(for: .milliseconds(30))
        }

        // Freeze capture before inference so transcription never includes later speech.
        let samples = recorder.finish()
        state = .transcribing
        guard !samples.isEmpty else { return "" }
        let text = try await recognizer.transcribe(samples)
        try Task.checkCancellation()
        return text
    }

    func stop() {
        guard state == .recording else { return }
        isStopRequested = true
    }

    /// Release the microphone immediately, including while inference is settling.
    func cancel() {
        recorder.stop()
    }
}

/// Owns the cached ASR runtime and keeps synchronous MLX inference off the main actor.
private actor VoiceRecognizer {
    private var model: WhisperModel?

    func transcribe(_ samples: [Float]) async throws -> String {
        try Task.checkCancellation()
        let recognizer: WhisperModel
        if let model {
            recognizer = model
        } else {
            recognizer = try await HubCache.default.loadModel(
                id: "mlx-community/whisper-large-v3-turbo-4bit",
                matching: ["*.safetensors", "*.json", "*.txt", "*.model"],
                using: { try await WhisperModel.fromDirectory($0) })
            model = recognizer
        }
        try Task.checkCancellation()
        var parts: [String] = []
        let windowSize = Int(AudioRecorder.sampleRate * 30)
        for start in stride(from: 0, to: samples.count, by: windowSize) {
            try Task.checkCancellation()
            let audio = MLXArray(Array(samples[start..<min(start + windowSize, samples.count)]))
            let output = recognizer.generate(
                audio: audio,
                generationParameters: STTGenerateParameters(
                    maxTokens: recognizer.defaultGenerationParameters.maxTokens,
                    temperature: 0, topP: 1,
                    chunkDuration: 30))
            try Task.checkCancellation()
            let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { parts.append(text) }
        }
        return parts.joined(separator: " ")
    }
}
