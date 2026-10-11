//
//  VoiceAudioEngine.swift
//  ModelCraft
//
//  Created by Hongshen on 7/10/26.
//

import AVFoundation

/// Full-duplex audio for voice mode. Microphone capture and speech playback share one
/// voice-processing engine so the system cancels the assistant's own voice from the
/// microphone, which lets the user interrupt while it speaks.
///
/// Capture is delivered as 16 kHz mono samples. Calls come from the main actor; tap and
/// playback callbacks arrive on audio threads.
final class VoiceAudioEngine: @unchecked Sendable {

    static let shared = VoiceAudioEngine()

    static let captureSampleRate: Double = 16000

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isConfigured = false
    private var playbackFormat: AVAudioFormat?

    private let lock = NSLock()
    private var captureHandler: (([Float]) -> Void)?
    private var queuedBuffers = 0
    /// Incremented by `stopPlayback()` so completions of discarded buffers are ignored.
    private var playbackGeneration = 0
    private var drainContinuations: [CheckedContinuation<Void, Never>] = []

    private init() {}

    // MARK: - Capture

    func startCapture(_ handler: @escaping ([Float]) -> Void) throws {
        lock.withLock { captureHandler = handler }
        do {
            try start()
        } catch {
            lock.withLock { captureHandler = nil }
            throw error
        }
    }

    func stopCapture() {
        lock.withLock { captureHandler = nil }
        stopIfIdle()
    }

    // MARK: - Playback

    func schedule(_ samples: [Float], sampleRate: Double) throws {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }

        try start()
        if playbackFormat != format {
            engine.connect(player, to: engine.mainMixerNode, format: format)
            playbackFormat = format
        }

        let generation = lock.withLock {
            queuedBuffers += 1
            return playbackGeneration
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.bufferPlayed(generation: generation)
        }
        if !player.isPlaying {
            player.play()
        }
    }

    /// Returns once every scheduled buffer has been played or playback was stopped.
    func playbackDrained() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if queuedBuffers == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                drainContinuations.append(continuation)
                lock.unlock()
            }
        }
    }

    func stopPlayback() {
        player.stop()
        let continuations = lock.withLock {
            playbackGeneration += 1
            queuedBuffers = 0
            defer { drainContinuations.removeAll() }
            return drainContinuations
        }
        continuations.forEach { $0.resume() }
        stopIfIdle()
    }

    private func bufferPlayed(generation: Int) {
        let continuations: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard generation == playbackGeneration else { return [] }
            queuedBuffers -= 1
            guard queuedBuffers == 0 else { return [] }
            defer { drainContinuations.removeAll() }
            return drainContinuations
        }
        continuations.forEach { $0.resume() }
    }

    // MARK: - Engine

    private func start() throws {
        guard !engine.isRunning else { return }
        if !isConfigured {
            try configure()
            isConfigured = true
        }
        engine.prepare()
        try engine.start()
    }

    private func stopIfIdle() {
        let isIdle = lock.withLock { captureHandler == nil && queuedBuffers == 0 }
        guard isIdle, engine.isRunning else { return }
        player.stop()
        engine.stop()
    }

    private func configure() throws {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(
            enableAdvancedDucking: false,
            duckingLevel: .min)

        // The voice-processing unit fails to initialize (-10875) unless its client-side
        // input and output formats match, so drive the output with the input's format.
        let inputFormat = input.outputFormat(forBus: 0)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: inputFormat)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)

        // Voice processing can expose several input channels; the first carries the
        // echo-cancelled microphone signal.
        guard let monoFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: inputFormat.sampleRate,
                  channels: 1,
                  interleaved: false),
              let captureFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: Self.captureSampleRate,
                  channels: 1,
                  interleaved: false),
              let converter = AVAudioConverter(from: monoFormat, to: captureFormat)
        else {
            throw NSError(domain: "VoiceAudioEngine", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create the microphone capture format"
            ])
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self,
                  let handler = self.lock.withLock({ self.captureHandler }),
                  let samples = Self.resample(
                      buffer, monoFormat: monoFormat, captureFormat: captureFormat, converter: converter)
            else { return }
            handler(samples)
        }
    }

    private static func resample(
        _ buffer: AVAudioPCMBuffer,
        monoFormat: AVAudioFormat,
        captureFormat: AVAudioFormat,
        converter: AVAudioConverter
    ) -> [Float]? {
        guard let channel = buffer.floatChannelData?[0],
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength)
        else { return nil }
        mono.frameLength = buffer.frameLength
        mono.floatChannelData![0].update(from: channel, count: Int(buffer.frameLength))

        let capacity = AVAudioFrameCount(
            Double(buffer.frameLength) * captureFormat.sampleRate / monoFormat.sampleRate) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else {
            return nil
        }
        var error: NSError?
        var consumed = false
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return mono
        }
        guard error == nil else { return nil }
        return Array(UnsafeBufferPointer(
            start: converted.floatChannelData![0],
            count: Int(converted.frameLength)))
    }
}
