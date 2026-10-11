//
//  TTSService.swift
//  ModelCraft
//
//  Created by Hongshen on 7/10/26.
//

import Observation
import Foundation

import MLXAudioTTS
import MLXAudioCore
import MLX

/// Speaks streamed assistant text: complete sentences are synthesized one at a time
/// with Qwen3-TTS and their PCM chunks are played through `VoiceAudioEngine` as soon as
/// they are decoded.
@MainActor
@Observable
final class TTSService {
    /// Whether a spoken response is in progress; text fed outside a response is ignored.
    private var isSpeaking = false

    var modelId: String = "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit"

    private var model: Qwen3TTSModel?

    /// The first synthesized sentence, reused as an in-context voice prompt so every
    /// later sentence keeps the same voice.
    @ObservationIgnored
    private var voiceReference: (audio: MLXArray, text: String)?

    private var pendingSentences: [String] = []
    private var synthesisTask: Task<Void, Never>?

    /// Characters already queued per assistant message, and whether that point is inside a code block.
    private var progress: [UUID: (spokenCount: Int, isInCodeBlock: Bool)] = [:]

    private static let streamingInterval = 0.5
    private static let sentenceTerminators: Set<Character> = ["。", "！", "？", "；", "!", "?", ";", "\n"]

    func loadModel() async {
        guard model == nil else { return }
        do {
            model = try await Qwen3TTSModel.fromPretrained(modelId)
        } catch {
            print("Failed to load TTS model: \(error.localizedDescription)")
        }
    }

    /// Starts a spoken response. Call before feeding text.
    func begin() {
        stop()
        isSpeaking = model != nil
    }

    /// Feeds the current content of a streaming assistant message; complete sentences
    /// that have not been spoken yet are queued for synthesis. A complete message also
    /// queues its unterminated tail.
    func feed(_ content: String, messageID: UUID, isComplete: Bool = false) {
        guard isSpeaking else { return }
        var (spokenCount, isInCodeBlock) = progress[messageID] ?? (0, false)
        let unspoken = content.dropFirst(spokenCount)
        guard let end = isComplete ? unspoken.endIndex : Self.sentenceEnds(in: unspoken).last else { return }
        let complete = unspoken[..<end]
        spokenCount += complete.count
        enqueue(complete, isInCodeBlock: &isInCodeBlock)
        progress[messageID] = (spokenCount, isInCodeBlock)
    }

    /// Waits until every queued sentence has been synthesized and played, then ends the response.
    func finish() async {
        guard isSpeaking else { return }
        await synthesisTask?.value
        guard isSpeaking else { return }
        await VoiceAudioEngine.shared.playbackDrained()
        guard isSpeaking else { return }
        VoiceAudioEngine.shared.stopPlayback()
        isSpeaking = false
    }

    func stop() {
        synthesisTask?.cancel()
        synthesisTask = nil
        pendingSentences.removeAll()
        progress.removeAll()
        VoiceAudioEngine.shared.stopPlayback()
        isSpeaking = false
    }

    private func enqueue(_ text: Substring, isInCodeBlock: inout Bool) {
        for line in text.split(separator: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                isInCodeBlock.toggle()
                continue
            }
            guard !isInCodeBlock else { continue }
            var start = line.startIndex
            for end in Self.sentenceEnds(in: line) + [line.endIndex] where start < end {
                let sentence = Self.speakableText(line[start..<end])
                start = end
                if sentence.contains(where: { $0.isLetter || $0.isNumber }) {
                    pendingSentences.append(sentence)
                }
            }
        }
        guard synthesisTask == nil, !pendingSentences.isEmpty else { return }
        synthesisTask = Task { [weak self] in
            await self?.synthesizePendingSentences()
        }
    }

    private func synthesizePendingSentences() async {
        // A cancelled task has already been replaced by `stop()`.
        defer { if !Task.isCancelled { synthesisTask = nil } }
        while !Task.isCancelled, let model, !pendingSentences.isEmpty {
            let sentence = pendingSentences.removeFirst()
            do {
                try await synthesize(sentence, model: model)
            } catch is CancellationError {
                return
            } catch {
                print("TTS failed: \(error.localizedDescription)")
            }
        }
    }

    private func synthesize(_ sentence: String, model: Qwen3TTSModel) async throws {
        let stream = model.generateStream(
            text: sentence,
            voice: nil,
            refAudio: voiceReference?.audio,
            refText: voiceReference?.text,
            language: nil,
            generationParameters: model.defaultGenerationParameters,
            streamingInterval: Self.streamingInterval)
        var samples: [Float] = []
        for try await generation in stream {
            try Task.checkCancellation()
            guard case .audio(let audio) = generation else { continue }
            let chunk = audio.asArray(Float.self)
            try VoiceAudioEngine.shared.schedule(chunk, sampleRate: Double(model.sampleRate))
            if voiceReference == nil {
                samples.append(contentsOf: chunk)
            }
        }
        if voiceReference == nil, !samples.isEmpty {
            voiceReference = (MLXArray(samples), sentence)
        }
    }

    /// Indices just past each sentence terminator, including an English period followed by whitespace.
    private static func sentenceEnds(in text: Substring) -> [Substring.Index] {
        var ends: [Substring.Index] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let character = text[index]
            if sentenceTerminators.contains(character)
                || (character == "." && next < text.endIndex && text[next].isWhitespace) {
                ends.append(next)
            }
            index = next
        }
        return ends
    }

    /// Removes Markdown syntax that should not be read aloud.
    private static func speakableText(_ line: Substring) -> String {
        var text = String(line)
        text = text.replacing(#/!?\[([^\]]*)\]\([^)]*\)/#) { String($0.output.1) }
        text = text.replacing(#/^\s*(#+|[-*+>]|\d+\.)\s+/#, with: "")
        text = text.replacing(#/[*_`#|~]/#, with: "")
        return text.trimmingCharacters(in: .whitespaces)
    }
}
