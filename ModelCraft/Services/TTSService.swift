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
import Hub

/// Speaks streamed assistant text: complete sentences are synthesized one at a time
/// with Qwen3-TTS and their PCM chunks are played through `VoiceAudioEngine` as soon as
/// they are decoded.
@MainActor
@Observable
final class TTSService {
    /// Whether a spoken response is in progress; text fed outside a response is ignored.
    private var isSpeaking = false
    /// Whether synthesized speech has started playing in the current response.
    private(set) var isPlaying = false

    var modelId: String = "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit"

    private var model: Qwen3TTSModel?

    /// Conditioning from the first synthesized sentence, reused as an in-context voice
    /// prompt so every later sentence keeps the same voice. It is prepared once because
    /// encoding the reference audio for every sentence delays each one.
    @ObservationIgnored
    private var voiceConditioning: Qwen3TTSModel.Qwen3TTSReferenceConditioning?

    private var pendingSentences: [String] = []
    private var synthesisTask: Task<Void, Never>?

    /// Characters already queued per assistant message, and whether that point is inside a code block.
    private var progress: [UUID: (spokenCount: Int, isInCodeBlock: Bool)] = [:]
    /// Whether any text of the current response has been queued.
    private var hasQueuedText = false

    /// Audio seconds synthesized per second, and seconds of speech per character, averaged
    /// over recent sentences. Synthesis competes with the language model for the GPU and
    /// often runs slower than playback while the reply streams.
    @ObservationIgnored
    private var synthesisSpeed: Double?
    @ObservationIgnored
    private var secondsPerCharacter: Double?

    private static let streamingInterval = 0.5
    /// Audio buffered before playback starts from silence while synthesis speed is unknown.
    private static let prebufferSeconds = 1.0
    /// The least audio buffered before playback starts from silence.
    private static let minimumLeadSeconds = 0.5
    private static let sentenceTerminators: Set<Character> = ["。", "！", "？", "；", "!", "?", ";", "\n"]
    /// The first text of a response may end at a clause so speech starts sooner.
    private static let clauseTerminators: Set<Character> = ["，", "、", "：", ",", ":"]
    private static let minimumClauseLength = 6

    func loadModel() async {
        guard model == nil else { return }
        do {
            model = try await HubApi.system.loadModel(
                id: modelId,
                matching: ["*.safetensors", "*.json", "*.txt", "*.wav"],
                using: Qwen3TTSModel.fromModelDirectory)
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
        guard isSpeaking, let answer = Self.answer(in: content) else { return }
        var (spokenCount, isInCodeBlock) = progress[messageID] ?? (0, false)
        let unspoken = answer.dropFirst(spokenCount)
        let end = isComplete
            ? unspoken.endIndex
            : Self.sentenceEnds(in: unspoken).last ?? (hasQueuedText ? nil : Self.firstClauseEnd(in: unspoken))
        guard let end else { return }
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
        isPlaying = false
    }

    func stop() {
        synthesisTask?.cancel()
        synthesisTask = nil
        pendingSentences.removeAll()
        progress.removeAll()
        hasQueuedText = false
        VoiceAudioEngine.shared.stopPlayback()
        isSpeaking = false
        isPlaying = false
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
                    hasQueuedText = true
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
        let stream = if let voiceConditioning {
            model.generateStream(
                text: sentence,
                conditioning: voiceConditioning,
                generationParameters: model.defaultGenerationParameters,
                streamingInterval: Self.streamingInterval)
        } else {
            model.generateStream(
                text: sentence,
                voice: nil,
                refAudio: nil,
                refText: nil,
                language: nil,
                generationParameters: model.defaultGenerationParameters,
                streamingInterval: Self.streamingInterval)
        }
        let sampleRate = Double(model.sampleRate)
        let start = ContinuousClock.now
        let estimatedDuration = secondsPerCharacter.map { $0 * Double(sentence.count) }
        var samples: [Float] = []
        var unscheduled: [Float] = []
        var hasStarted = false
        for try await generation in stream {
            try Task.checkCancellation()
            guard case .audio(let audio) = generation else { continue }
            let chunk = audio.asArray(Float.self)
            samples.append(contentsOf: chunk)
            unscheduled.append(contentsOf: chunk)
            // A sentence that is already playing keeps its queue filled. Otherwise playback
            // waits, after the previous sentence if needed, until enough audio is ahead that
            // the rest of the sentence is synthesized before it is needed, so pauses fall
            // between sentences instead of every few words.
            let queued = VoiceAudioEngine.shared.queuedPlaybackDuration
            let remaining = estimatedDuration.map { max(0, $0 - Double(samples.count) / sampleRate) }
            if (hasStarted && queued > 0)
                || queued + Double(unscheduled.count) / sampleRate >= requiredLead(remaining: remaining) {
                try play(&unscheduled, sampleRate: sampleRate)
                hasStarted = true
            }
        }
        try play(&unscheduled, sampleRate: sampleRate)
        guard !samples.isEmpty else { return }
        let duration = Double(samples.count) / sampleRate
        let elapsed = start.duration(to: .now) / .seconds(1)
        synthesisSpeed = Self.average(synthesisSpeed, duration / elapsed)
        secondsPerCharacter = Self.average(secondsPerCharacter, duration / Double(sentence.count))
        if voiceConditioning == nil {
            voiceConditioning = try await Task.detached { [samples] in
                try model.prepareReferenceConditioning(
                    refAudio: MLXArray(samples), refText: sentence, language: nil)
            }.value
        }
    }

    /// Audio to have ahead of playback before it starts from silence. Synthesizing the
    /// remaining audio `r` at speed `s` takes `r / s` seconds while playing it takes `r`,
    /// so `r × (1 / s − 1)` must already be buffered, plus a margin for estimation error.
    private func requiredLead(remaining: Double?) -> Double {
        guard let remaining, let synthesisSpeed else { return Self.prebufferSeconds }
        return max(Self.minimumLeadSeconds, remaining * (1 / synthesisSpeed - 1) * 1.2)
    }

    private static func average(_ current: Double?, _ sample: Double) -> Double {
        current.map { ($0 + sample) / 2 } ?? sample
    }

    private func play(_ samples: inout [Float], sampleRate: Double) throws {
        guard !samples.isEmpty else { return }
        try VoiceAudioEngine.shared.schedule(samples, sampleRate: sampleRate)
        samples.removeAll()
        isPlaying = true
    }

    /// The answer after leading model reasoning, or `nil` while the reasoning streams.
    private static func answer(in content: String) -> Substring? {
        let leading = content.drop { $0.isWhitespace }
        guard leading.hasPrefix("<think>") else { return Substring(content) }
        return leading.range(of: "</think>").map { leading[$0.upperBound...] }
    }

    /// The index just past the first clause terminator that ends a long enough clause.
    private static func firstClauseEnd(in text: Substring) -> Substring.Index? {
        var length = 0
        for index in text.indices {
            length += 1
            if length >= minimumClauseLength, clauseTerminators.contains(text[index]) {
                return text.index(after: index)
            }
        }
        return nil
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
