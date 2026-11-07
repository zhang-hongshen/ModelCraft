//
//  AudioRecorder.swift
//  ModelCraft
//
//  Created by Hongshen on 4/4/26.
//

import Foundation
import AVFoundation

/// Collects microphone samples as 16 kHz mono.
/// The capture callback writes on an audio thread and reads happen on the main thread,
/// so the stored samples are guarded by a lock.
final class AudioRecorder: @unchecked Sendable {

    static let sampleRate: Double = 16000

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var rms: Float = 0

    /// The loudness of the latest captured buffer, scaled to 0...1.
    var level: Float {
        lock.withLock {
            let decibels = 20 * log10(max(rms, 1e-6))
            let normalized = min(1, max(0, (decibels + 50) / 38))
            return normalized * normalized
        }
    }

    func start() async throws {
        try await Self.requestMicrophoneAccess()
        try startEngine()
    }

    func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        lock.withLock {
            samples.removeAll()
            rms = 0
        }
    }

    /// Stops capture and transfers the complete recording before clearing the meter.
    func finish() -> [Float] {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        return lock.withLock {
            let recording = samples
            samples.removeAll()
            rms = 0
            return recording
        }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        // The input can expose several channels; the first carries the microphone signal.
        guard inputFormat.sampleRate > 0,
              let monoFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: inputFormat.sampleRate,
                  channels: 1,
                  interleaved: false),
              let captureFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: Self.sampleRate,
                  channels: 1,
                  interleaved: false),
              let converter = AVAudioConverter(from: monoFormat, to: captureFormat)
        else {
            throw NSError(domain: "AudioRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create the microphone capture format"
            ])
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self,
                  let floats = Self.resample(
                      buffer, monoFormat: monoFormat, captureFormat: captureFormat, converter: converter)
            else { return }
            let rms = sqrt(floats.reduce(0) { $0 + $1 * $1 } / max(Float(floats.count), 1))
            self.lock.withLock {
                self.samples.append(contentsOf: floats)
                self.rms = rms
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
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

    private static func requestMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            if !granted {
                throw MicrophonePermissionError.denied
            }
        default:
            throw MicrophonePermissionError.denied
        }
    }
}

enum MicrophonePermissionError: LocalizedError {
    case denied

    var errorDescription: String? {
        "Microphone access is required for recording. Please grant access in System Settings > Privacy & Security > Microphone."
    }
}
