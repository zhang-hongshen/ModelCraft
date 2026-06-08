// Copyright © 2024 Apple Inc.

import AVFoundation
import Foundation
import MLX


public class MusicGenIO {
    
    /// Save audio samples to a WAV file using Apple's AVFoundation framework.
    ///
    /// - Parameters:
    ///   - to: Output file url.
    ///   - audio: Audio samples as MLXArray with values in range [-1, 1].
    ///   - samplingRate: Sample rate in Hz (e.g. 32000).
    public static func saveAudio(to url: URL, audio: MLXArray, samplingRate: Int) throws {
        // Clip audio to [-1, 1]
        let clipped = clip(audio, min: -1, max: 1)
        // Convert to Int16
        let int16Audio = (clipped * 32767).asType(.int16)

        eval(int16Audio)

        let totalSamples: Int
        let numChannels: Int

        if int16Audio.ndim == 1 {
            totalSamples = int16Audio.dim(0)
            numChannels = 1
        } else if int16Audio.ndim == 2 {
            totalSamples = int16Audio.dim(0)
            numChannels = int16Audio.dim(1)
        } else {
            // Flatten to 1D
            let flat = int16Audio.reshaped(-1)
            eval(flat)
            totalSamples = flat.dim(0)
            numChannels = 1
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(samplingRate),
            channels: AVAudioChannelCount(numChannels),
            interleaved: true
        ) else {
            throw AudioError.invalidFormat
        }


        let audioFile = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(totalSamples)
        ) else {
            throw AudioError.bufferCreationFailed
        }
        buffer.frameLength = AVAudioFrameCount(totalSamples)

        let flatAudio: MLXArray
        if int16Audio.ndim > 1 {
            flatAudio = int16Audio.reshaped(-1)
        } else {
            flatAudio = int16Audio
        }
        eval(flatAudio)

        // Get raw Int16 data from MLXArray
        let dataCount = totalSamples * numChannels
        let int16Pointer = buffer.int16ChannelData!

        // Copy from MLXArray to the buffer
        // MLXArray data access
        let mlxData = flatAudio.asData(Int16.self)
        for i in 0 ..< dataCount {
            int16Pointer[0][i] = mlxData[i]
        }

        try audioFile.write(from: buffer)
    }

    // MARK: - Audio Error

    enum AudioError: Error, LocalizedError {
        case invalidFormat
        case bufferCreationFailed
        case fileCreationFailed

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return "Failed to create audio format"
            case .bufferCreationFailed:
                return "Failed to create audio buffer"
            case .fileCreationFailed:
                return "Failed to create audio file"
            }
        }
    }
}


extension MLXArray {
    /// Access raw data of MLXArray as a typed array
    func asData<T: HasDType>(_ type: T.Type) -> [T] {
        let count = self.size
        return withUnsafePointer(to: self) { _ in
            // Force evaluation
            MLX.eval(self)
            // Use asArray for data extraction
            return asArray(type)
        }
    }
}
