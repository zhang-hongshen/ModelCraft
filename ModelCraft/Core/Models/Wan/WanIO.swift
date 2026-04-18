//
//  WanIO.swift
//  ModelCraft
//
//  Created by Hongshen on 15/4/26.
//

import Foundation
import AVFoundation
import CoreVideo

import MLX

public enum WanLoaderError: Error, LocalizedError {
    case invalidIndexFile(URL)
    case fileNotFound(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidIndexFile(let url): return "Invalid shard index file: \(url.path)"
        case .fileNotFound(let url):
            return "File not found: \(url.path)"
        }
    }
}


public enum WanIOError: Error, LocalizedError {
    case videoWriterFailed(String)

    public var errorDescription: String? {
        switch self {
        case .videoWriterFailed(let msg): return "Video writer failed: \(msg)"
        }
    }
}

public enum WanIO {
    public static func saveVideo(frames: MLXArray, fps: Int = 16, outputPath: URL) throws {
        let fm = FileManager.default
        let dir = outputPath.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: outputPath.path) {
            try fm.removeItem(at: outputPath)
        }

        var f = frames
        if Int(f.ndim) == 5 { f = f[0, 0..., 0..., 0..., 0...] }
        if f.min().item(Float.self) < 0 {
            f = (f + MLXArray(1.0)) / MLXArray(2.0)
        }
        let u8 = MLX.clip(f * MLXArray(255.0), min: MLXArray(0), max: MLXArray(255)).asType(.uint8)
        let bytes = Array(u8.asArray(UInt8.self))
        let shape = u8.shape
        let t = Int(shape[0]), h = Int(shape[1]), w = Int(shape[2])

        let writer = try AVAssetWriter(outputURL: outputPath, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, w * h * 8),
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
        ]
        
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)

        guard writer.canAdd(input) else {
            throw WanIOError.videoWriterFailed("Cannot add AVAssetWriterInput.")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw WanIOError.videoWriterFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        let frameStride = h * w * 3
        for frameIndex in 0..<t {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.001)
            }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                w,
                h,
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &pixelBuffer
            )
            guard status == kCVReturnSuccess, let pb = pixelBuffer else {
                throw WanIOError.videoWriterFailed("CVPixelBufferCreate failed.")
            }

            CVPixelBufferLockBaseAddress(pb, [])
            defer { CVPixelBufferUnlockBaseAddress(pb, []) }
            guard let baseAddr = CVPixelBufferGetBaseAddress(pb) else {
                throw WanIOError.videoWriterFailed("Pixel buffer base address is nil.")
            }
            let dst = baseAddr.assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
            let srcOffset = frameIndex * frameStride

            for y in 0..<h {
                let srcRow = srcOffset + y * w * 3
                let dstRow = y * bytesPerRow
                for x in 0..<w {
                    let s = srcRow + x * 3
                    let d = dstRow + x * 4
                    let r = bytes[s]
                    let g = bytes[s + 1]
                    let b = bytes[s + 2]
                    dst[d] = b
                    dst[d + 1] = g
                    dst[d + 2] = r
                    dst[d + 3] = 255
                }
            }

            let pts = CMTime(value: Int64(frameIndex), timescale: Int32(fps))
            if !adaptor.append(pb, withPresentationTime: pts) {
                throw WanIOError.videoWriterFailed(
                    writer.error?.localizedDescription ?? "append frame \(frameIndex) failed"
                )
            }
        }

        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        var finishError: Error?
        writer.finishWriting {
            finishError = writer.error
            sem.signal()
        }
        sem.wait()
        if let finishError {
            throw WanIOError.videoWriterFailed(finishError.localizedDescription)
        }
    }
}
