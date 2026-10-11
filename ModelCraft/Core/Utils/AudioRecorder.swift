//
//  AudioRecorder.swift
//  ModelCraft
//
//  Created by Hongshen on 4/4/26.
//

import Foundation
import AVFoundation

/// Collects microphone samples (16 kHz mono) from the shared voice engine.
/// The capture callback writes on an audio thread and reads happen on the main thread,
/// so the stored samples are guarded by a lock.
final class AudioRecorder: @unchecked Sendable {

    private let lock = NSLock()
    private var samples: [Float] = []
    private var rms: Float = 0

    /// The loudness of the latest captured buffer, scaled to 0...1.
    var level: Float {
        lock.withLock { min(rms * 5, 1) }
    }

    /// Number of samples captured since recording started.
    var sampleCount: Int {
        lock.withLock { samples.count }
    }

    func start() async throws {
        try await Self.requestMicrophoneAccess()
        try VoiceAudioEngine.shared.startCapture { [weak self] floats in
            guard let self else { return }
            let rms = sqrt(floats.reduce(0) { $0 + $1 * $1 } / max(Float(floats.count), 1))
            self.lock.withLock {
                self.samples.append(contentsOf: floats)
                self.rms = rms
            }
        }
    }

    func stop() {
        VoiceAudioEngine.shared.stopCapture()
        lock.withLock {
            samples.removeAll()
            rms = 0
        }
    }

    /// The samples from `start` to the end, and the end position.
    func recordedSamples(from start: Int) -> (samples: [Float], end: Int) {
        lock.withLock { (Array(samples[min(start, samples.count)...]), samples.count) }
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
