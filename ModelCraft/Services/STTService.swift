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
import Hub

@MainActor
@Observable
final class STTService {
    /// The transcript of the utterance being recorded, including provisional text, shown
    /// while the user speaks.
    private(set) var transcript: String = ""
    /// The microphone level while listening, scaled to 0...1; zero while muted.
    private(set) var level: Float = 0
    /// Whether an utterance has started and is being recorded.
    private(set) var isHearingSpeech = false
    /// While muted, the microphone is ignored: no utterance starts and an utterance in
    /// progress ends as if the user stopped speaking.
    var isMuted = false

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
            model = try await Self.loadModel(id: modelId)
        } catch {
            print("Failed to load model: \(error.localizedDescription)")
        }
    }

    /// Loads a Qwen3-ASR model from `HubApi.system`, downloading it there when absent.
    nonisolated static func loadModel(id: String) async throws -> Qwen3ASRModel {
        try await HubApi.system.loadModel(
            id: id,
            matching: ["*.safetensors", "*.json", "*.txt"],
            using: Qwen3ASRModel.fromModelDirectory)
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
            level = 0
            isHearingSpeech = false
        }

        var speech: Duration = .zero
        while speech < Self.speechOnset {
            guard await waitForNextPoll() else { return nil }
            speech = level > Self.speechLevel ? speech + Self.levelPollInterval : .zero
        }
        isHearingSpeech = true
        onSpeech()

        let config = StreamingConfig(
            decodeIntervalSeconds: 1.0,
            maxCachedWindows: 60,
            delayPreset: .custom(ms: streamingDelayMs),
            // The session defaults to English, which garbles other languages; `nil` lets the
            // model detect the language itself.
            language: nil,
            maxTokensPerPass: 1024
        )
        let session = StreamingInferenceSession(model: model, config: config)
        let events = Task {
            for await event in session.events {
                switch event {
                case .provisional, .stats:
                    break
                case .displayUpdate(let confirmedText, let provisionalText):
                    // Provisional text can end with a tag that is still being decoded.
                    transcript = Self.removingLanguageTags(confirmedText + provisionalText)
                        .replacing(/(^|\s)language(\s+[A-Za-z]*)?\s*(<[a-z_]*)?$/, with: "")
                case .confirmed(let text), .ended(let text):
                    transcript = Self.removingLanguageTags(text)
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
            silence = level > Self.speechLevel ? .zero : silence + Self.levelPollInterval
        }

        _ = feed(session, from: readPosition)
        session.stop()
        await events.value
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Without a language hint the model prefixes each decoded window with
    /// `language <Name><asr_text>`, which the streaming session leaves in the text.
    private static func removingLanguageTags(_ text: String) -> String {
        text.replacing(/language\s+[A-Za-z]+\s*<asr_text>/, with: "")
    }

    /// Waits one poll interval and samples the microphone level. Returns `false` once the
    /// listening task is cancelled.
    private func waitForNextPoll() async -> Bool {
        try? await Task.sleep(for: Self.levelPollInterval)
        level = isMuted ? 0 : recorder.level
        return !Task.isCancelled
    }

    /// Sends the samples captured since `position` to the session and returns the new
    /// position. Samples captured while muted are skipped.
    private func feed(_ session: StreamingInferenceSession, from position: Int) -> Int {
        let (samples, end) = recorder.recordedSamples(from: position)
        if !samples.isEmpty, !isMuted {
            session.feedAudio(samples: samples)
        }
        return end
    }
}
