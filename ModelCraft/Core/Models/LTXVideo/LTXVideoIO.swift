//
//  LTXVideoIO.swift
//  ModelCraft
//

import AVFoundation
import CoreVideo
import Foundation

import MLX

public enum LTXVideoIOError: Error, LocalizedError {
    case videoWriterFailed(String)

    public var errorDescription: String? {
        switch self {
        case .videoWriterFailed(let message):
            return "Video writer failed: \(message)"
        }
    }
}

public enum LTXVideoIO {
    public static func saveVideo(frames: MLXArray, fps: Int = 24, outputPath: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: outputPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: outputPath.path) {
            try fileManager.removeItem(at: outputPath)
        }

        var video = frames
        if Int(video.ndim) == 5 {
            video = video[0, 0..., 0..., 0..., 0...]
        }
        if video.min().item(Float.self) < 0 {
            video = (video + 1) / 2
        }

        let frameCount = Int(video.shape[0])
        let height = Int(video.shape[1])
        let width = Int(video.shape[2])

        let writer = try AVAssetWriter(outputURL: outputPath, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, width * height * 8),
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attrs
        )

        guard writer.canAdd(input) else {
            throw LTXVideoIOError.videoWriterFailed("Cannot add AVAssetWriterInput.")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw LTXVideoIOError.videoWriterFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        for frameIndex in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.001)
            }

            let frame = MLX.clip(
                video[frameIndex, 0..., 0..., 0...] * 255,
                min: MLXArray(0),
                max: MLXArray(255)
            ).asType(.uint8)
            let bytes = Array(frame.asArray(UInt8.self))

            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &pixelBuffer
            )
            guard status == kCVReturnSuccess, let pixelBuffer else {
                throw LTXVideoIOError.videoWriterFailed("CVPixelBufferCreate failed.")
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
            guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                throw LTXVideoIOError.videoWriterFailed("Pixel buffer base address is nil.")
            }

            let destination = baseAddress.assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            for y in 0..<height {
                let srcRow = y * width * 3
                let dstRow = y * bytesPerRow
                for x in 0..<width {
                    let src = srcRow + x * 3
                    let dst = dstRow + x * 4
                    destination[dst] = bytes[src + 2]
                    destination[dst + 1] = bytes[src + 1]
                    destination[dst + 2] = bytes[src]
                    destination[dst + 3] = 255
                }
            }

            let pts = CMTime(value: Int64(frameIndex), timescale: Int32(fps))
            if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
                throw LTXVideoIOError.videoWriterFailed(
                    writer.error?.localizedDescription ?? "append frame \(frameIndex) failed"
                )
            }
        }

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        var finishError: Error?
        writer.finishWriting {
            finishError = writer.error
            semaphore.signal()
        }
        semaphore.wait()

        if let finishError {
            throw LTXVideoIOError.videoWriterFailed(finishError.localizedDescription)
        }
    }
}

