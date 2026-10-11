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

@MainActor
@Observable
final class STTService {
    /// The transcript of the utterance being recorded, shown while the user speaks.
    var transcript: String = ""

    // Streaming parameters
    var streamingDelayMs: Int = 480  // .agent default

    // Model configuration
    var modelId: String = "mlx-community/Qwen3-ASR-0.6B-4bit"

    private var model: Qwen3ASRModel?
    private let recorder = AudioRecorder()

    init() {}

    func loadModel() async {
        guard model == nil else { return }
        do {
            model = try await Qwen3ASRModel.fromPretrained(modelId)
        } catch {
            print("Failed to load model: \(error.localizedDescription)")
        }
    }

    // MARK: - Listening

    private static let levelPollInterval: Duration = .milliseconds(100)
    private static let speechLevel: Float = 0.1
    /// Speech must last this long before it counts, so short noises or residual echo
    /// of the assistant's voice do not start an utterance.
    private static let speechOnset: Duration = .milliseconds(300)
    private static let endOfUtterancePause: Duration = .milliseconds(1000)
    /// Audio kept from before the onset was confirmed so the first syllable is transcribed.
    private static let preRollSamples = Int(VoiceAudioEngine.captureSampleRate * 0.5)

    /// Records one utterance: waits for speech, calls `onSpeech` when it starts, ends after
    /// a pause, and returns the trimmed transcript. Returns `nil` when recording could not
    /// start or the calling task was cancelled.
    func listen(onSpeech: () -> Void = {}) async -> String? {
        guard let model else {
            print("Model not loaded")
            return nil
        }
        do {
            try await recorder.start()
        } catch {
            print(error.localizedDescription)
            return nil
        }
        defer {
            recorder.stop()
            transcript = ""
        }

        var speech: Duration = .zero
        while speech < Self.speechOnset {
            guard await waitForNextPoll() else { return nil }
            speech = recorder.level > Self.speechLevel ? speech + Self.levelPollInterval : .zero
        }
        onSpeech()

        let config = StreamingConfig(
            decodeIntervalSeconds: 1.0,
            maxCachedWindows: 60,
            delayPreset: .custom(ms: streamingDelayMs),
            maxTokensPerPass: 1024
        )
        let session = StreamingInferenceSession(model: model, config: config)
        let events = Task {
            for await event in session.events {
                switch event {
                case .displayUpdate, .provisional, .stats:
                    break
                case .confirmed(let text), .ended(let text):
                    transcript = text
                }
            }
        }

        var readPosition = max(0, recorder.sampleCount - Self.preRollSamples)
        var silence: Duration = .zero
        while silence < Self.endOfUtterancePause {
            guard await waitForNextPoll() else {
                session.cancel()
                events.cancel()
                return nil
            }
            readPosition = feed(session, from: readPosition)
            silence = recorder.level > Self.speechLevel ? .zero : silence + Self.levelPollInterval
        }

        _ = feed(session, from: readPosition)
        session.stop()
        await events.value
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Waits one poll interval. Returns `false` once the listening task is cancelled.
    private func waitForNextPoll() async -> Bool {
        try? await Task.sleep(for: Self.levelPollInterval)
        return !Task.isCancelled
    }

    /// Sends the samples captured since `position` to the session and returns the new position.
    private func feed(_ session: StreamingInferenceSession, from position: Int) -> Int {
        let (samples, end) = recorder.recordedSamples(from: position)
        if !samples.isEmpty {
            session.feedAudio(samples: samples)
        }
        return end
    }
}
