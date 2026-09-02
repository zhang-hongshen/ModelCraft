//
//  H3IO.swift
//  ModelCraft
//
//  Created by Hongshen on 27/8/26.
//


import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics
import ImageIO
import Metal
import MLX


/// Cursors shared with the two mux queues. Each field is touched by exactly one
/// queue, and both are joined before the values are read.
private final class MuxCursor: @unchecked Sendable {
    var frame = 0
    var sample = 0
}

/// Joins AVFoundation's two required callback queues without blocking a Swift
/// concurrency worker. All mutable state is protected by the lock; the class is
/// the containment boundary for the callback API's non-Sendable objects.
private final class MuxCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var firstError: String?
    private var continuation: CheckedContinuation<String?, Never>?

    init(remaining: Int, continuation: CheckedContinuation<String?, Never>) {
        self.remaining = remaining
        self.continuation = continuation
    }

    func finish(error: String? = nil) {
        lock.lock()
        if firstError == nil { firstError = error }
        remaining -= 1
        let result = remaining == 0 ? firstError : nil
        let done = remaining == 0 ? continuation : nil
        if remaining == 0 { continuation = nil }
        lock.unlock()
        done?.resume(returning: result)
    }
}

/// H3 media input/output boundary.
///
/// The model produces decoded RGB frames and stereo PCM. H3IO keeps the
/// AVFoundation muxing and WAV details out of the Evaluator and sampling code.
///
/// H3 generates video and audio jointly, so handing back a silent video and a
/// loose wav throws away the thing that makes the model interesting. The mp4
/// carries both; the wav is a convenience and a fallback.
enum H3IO {

    /// Converts decoded H3 tensors and saves the final video to one file.
    static func save(
        frames: MLXArray,
        waveform: MLXArray,
        to url: URL,
        fps: Double,
        sampleRate: Int
    ) async throws -> H3EvaluatorResult {
        let samples = deinterleave(waveform)
        let frameCount = frames.dim(2)
        let frameHeight = frames.dim(3)
        let frameWidth = frames.dim(4)
        let rgb = clip((frames + 1.0) * 127.5, min: 0.0, max: 255.0)
            .transposed(0, 2, 3, 4, 1)
            .reshaped([frameCount, frameHeight, frameWidth, 3])
        let alpha = MLXArray.full(
            [frameCount, frameHeight, frameWidth, 1],
            values: MLXArray(255.0 as Float))
        let argb = concatenated([alpha, rgb], axis: -1).asType(.uint8)
        eval(argb)

        do {
            try await saveVideo(
                argb: argb,
                waveform: samples,
                to: url,
                fps: fps,
                sampleRate: sampleRate)
        } catch {
            try await saveVideo(
                argb: argb,
                waveform: samples,
                to: url,
                fps: fps,
                sampleRate: sampleRate,
                withAudio: false)
        }

        return H3EvaluatorResult(
            video: url,
            frameCount: frameCount,
            width: frameWidth,
            height: frameHeight,
            seconds: Double(frameCount) / fps)
    }

    /// 16-bit PCM stereo, written by hand because the alternative is an
    /// `AVAudioFile` and a format conversion for a file this simple.
    static func writeWAV(samples: [[Float]], to url: URL,
                         sampleRate: Int = H3Configuration.presetH3BaseFL2VA.audioSampleRate) throws {
        guard samples.count == 2 else {
            throw H3EvaluatorError.invalidRequest(rule: "audio must be stereo",
                                         detail: "\(samples.count) channel(s)",
                                         remedy: "the audio VAE decodes to two channels.")
        }
        let channels = 2, bytesPerSample = 2
        let frames = samples[0].count
        let dataSize = frames * channels * bytesPerSample

        var data = Data()
        data.reserveCapacity(44 + dataSize)
        func u32(_ v: UInt32) { var x = v.littleEndian; data.append(withUnsafeBytes(of: &x) { Data($0) }) }
        func u16(_ v: UInt16) { var x = v.littleEndian; data.append(withUnsafeBytes(of: &x) { Data($0) }) }

        data.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        u32(16)                                   // PCM header size
        u16(1)                                    // PCM
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * channels * bytesPerSample))
        u16(UInt16(channels * bytesPerSample))
        u16(16)                                   // bits per sample
        data.append(contentsOf: Array("data".utf8))
        u32(UInt32(dataSize))

        for i in 0 ..< frames {
            for c in 0 ..< channels {
                let clamped = max(-1.0, min(1.0, samples[c][i]))
                u16(UInt16(bitPattern: Int16(clamped * 32767.0)))
            }
        }
        try data.write(to: url)
    }

    /// One mp4 carrying both streams, colour-tagged, with every failure path
    /// checked.
    ///
    /// Both tracks are driven by `requestMediaDataWhenReady`, allowing
    /// AVFoundation to pull each input at its own pace.
    ///
    /// Audio is delivered in **1024-sample chunks**, matching AAC's frame size.
    ///
    /// - Parameter argb: `[T, H, W, 4]` uint8, alpha first.
    static func saveVideo(argb: MLXArray, waveform: [[Float]], to url: URL,
                          fps: Double, sampleRate: Int,
                          withAudio: Bool = true) async throws {
        let frameCount = argb.dim(0), height = argb.dim(1), width = argb.dim(2)
        guard frameCount > 0 else {
            throw H3EvaluatorError.invalidRequest(rule: "nothing to write", detail: "no frames",
                                         remedy: "the decode produced an empty tensor.")
        }
        func fail(_ m: String) -> H3EvaluatorError {
            H3EvaluatorError.unreadable(path: url.path, reason: m)
        }

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(videoInput) else { throw fail("AVAssetWriter refused the video input") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        var audioFormat: CMFormatDescription?
        if withAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw fail("AVAssetWriter refused the audio input") }
            writer.add(input)
            audioInput = input

            var asbd = AudioStreamBasicDescription(
                mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                                 layoutSize: 0, layout: nil, magicCookieSize: 0,
                                                 magicCookie: nil, extensions: nil,
                                                 formatDescriptionOut: &audioFormat) == noErr,
                  audioFormat != nil else {
                throw fail("could not describe the PCM source format")
            }
        }

        guard writer.startWriting() else {
            throw fail("startWriting failed: " + (writer.error?.localizedDescription ?? "unknown"))
        }
        writer.startSession(atSourceTime: .zero)

        let rowBytes = width * 4
        let frameStride = height * rowBytes
        let timescale: CMTimeScale = 90_000

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw fail("could not create a Metal device")
        }
        let contiguous = argb.contiguous()
        guard let mtlBuffer = contiguous.asMTLBuffer(device: device, noCopy: true) else {
            throw fail("could not wrap the video frames as a zero-copy MTLBuffer")
        }
        nonisolated(unsafe) let source = mtlBuffer.contents()

        // AVFoundation's writer objects are not Sendable, but each is touched by
        // exactly one serial queue here and `finishWriting` happens after both
        // have finished. That is the contract the API documents.
        nonisolated(unsafe) let vIn = videoInput
        nonisolated(unsafe) let vAdaptor = adaptor
        nonisolated(unsafe) let wr = writer
        let cursor = MuxCursor()

        let muxError = await withCheckedContinuation { continuation in
            let completion = MuxCompletion(remaining: withAudio ? 2 : 1,
                                           continuation: continuation)
            vIn.requestMediaDataWhenReady(on: DispatchQueue(label: "h3.video.mux")) {
                while vIn.isReadyForMoreMediaData {
                    let i = cursor.frame
                    if i >= frameCount {
                        vIn.markAsFinished(); completion.finish(); return
                    }
                guard let pool = vAdaptor.pixelBufferPool else {
                    vIn.markAsFinished(); completion.finish(error: "pixel buffer pool unavailable")
                    return
                }
                var pb: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess,
                      let buffer = pb else {
                    vIn.markAsFinished()
                    completion.finish(error: "could not allocate a pixel buffer for frame \(i)")
                    return
                }
                CVPixelBufferLockBaseAddress(buffer, [])
                if let base = CVPixelBufferGetBaseAddress(buffer) {
                    let dstStride = CVPixelBufferGetBytesPerRow(buffer)
                    let frameBase = source.advanced(by: i * frameStride)
                    for y in 0 ..< height {
                        memcpy(base.advanced(by: y * dstStride), frameBase + y * rowBytes, rowBytes)
                    }
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                let pts = CMTime(value: CMTimeValue(Double(i) / fps * Double(timescale)),
                                 timescale: timescale)
                guard vAdaptor.append(buffer, withPresentationTime: pts) else {
                    vIn.markAsFinished()
                    completion.finish(error: "video append failed at frame \(i): "
                                      + (wr.error?.localizedDescription ?? "unknown"))
                    return
                }
                cursor.frame = i + 1
                }
            }

            if let audioIn = audioInput, let format = audioFormat {
                nonisolated(unsafe) let aIn = audioIn
                let total = waveform[0].count
                aIn.requestMediaDataWhenReady(on: DispatchQueue(label: "h3.audio.mux")) {
                    while aIn.isReadyForMoreMediaData {
                    let offset = cursor.sample
                    if offset >= total { aIn.markAsFinished(); completion.finish(); return }
                    let n = min(1024, total - offset)
                    var interleaved = [Float](repeating: 0, count: n * 2)
                    for j in 0 ..< n {
                        interleaved[j * 2] = waveform[0][offset + j]
                        interleaved[j * 2 + 1] = waveform[1][offset + j]
                    }
                    let byteCount = n * 2 * MemoryLayout<Float>.size
                    var block: CMBlockBuffer?
                    guard CMBlockBufferCreateWithMemoryBlock(
                            allocator: kCFAllocatorDefault, memoryBlock: nil,
                            blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
                            customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
                            flags: 0, blockBufferOut: &block) == noErr, let bb = block,
                          CMBlockBufferAssureBlockMemory(bb) == noErr else {
                        aIn.markAsFinished()
                        completion.finish(error: "could not allocate an audio block buffer")
                        return
                    }
                    interleaved.withUnsafeBytes { raw in
                        _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: bb,
                                                          offsetIntoDestination: 0,
                                                          dataLength: byteCount)
                    }
                    var sample: CMSampleBuffer?
                    var timing = CMSampleTimingInfo(
                        duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                        presentationTimeStamp: CMTime(value: CMTimeValue(offset),
                                                      timescale: CMTimeScale(sampleRate)),
                        decodeTimeStamp: .invalid)
                    var sizes = [8]
                    guard CMSampleBufferCreateReady(
                            allocator: kCFAllocatorDefault, dataBuffer: bb,
                            formatDescription: format, sampleCount: n,
                            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                            sampleSizeEntryCount: 1, sampleSizeArray: &sizes,
                            sampleBufferOut: &sample) == noErr, let sb = sample else {
                        aIn.markAsFinished()
                        completion.finish(error: "could not build an audio sample buffer")
                        return
                    }
                    guard aIn.append(sb) else {
                        aIn.markAsFinished()
                        completion.finish(error: "audio append failed at sample \(offset): "
                                          + (wr.error?.localizedDescription ?? "unknown"))
                        return
                    }
                    cursor.sample = offset + n
                    }
                }
            }
        }

        // Both queues read `source` straight out of MLX's storage. ARC's last
        // use of the array and its Metal wrapper is the `contents()` call above,
        // so without this it is free to release them — and free the storage —
        // while a queue is still copying.
        withExtendedLifetime(contiguous) { withExtendedLifetime(mtlBuffer) {} }
        if let muxError { throw fail(muxError) }

        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw fail("writing ended in status \(writer.status.rawValue): "
                       + (writer.error?.localizedDescription ?? "unknown"))
        }
    }
}

// MARK: - Image input

extension H3IO {
    enum ImageError: Swift.Error, CustomStringConvertible {
        case unreadable(String, String)

        var description: String {
            switch self {
            case .unreadable(let path, let reason):
                "cannot read \(path): \(reason)"
            }
        }
    }

    /// Image file -> `[1, 3, 1, H, W]` in `[-1, 1]` for the Visual VAE.
    static func image(
        at path: String,
        fit: (width: Int, height: Int)? = nil
    ) throws -> MLXArray {
        var width = fit?.width
        var height = fit?.height
        if width == nil || height == nil {
            let size = try imageSize(at: path)
            width = max(32, size.width / 32 * 32)
            height = max(32, size.height / 32 * 32)
        }

        return (try imageHWC(at: path, width: width!, height: height!) * 2.0 - 1.0)
            .squeezed(axis: 0)
            .transposed(2, 0, 1)
            .expandedDimensions(axes: [0, 2])
    }

    /// Pixel dimensions without decoding the image body.
    static func imageSize(at path: String) throws -> (width: Int, height: Int) {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw ImageError.unreadable(path, "could not read image dimensions")
        }
        return (width, height)
    }

    /// Image file -> `[1, H, W, 3]` in `[0, 1]` for the H3 Encoder vision tower.
    static func imageHWC(
        at path: String,
        width: Int,
        height: Int
    ) throws -> MLXArray {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ImageError.unreadable(path, "not a decodable image")
        }

        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = buffer.withUnsafeMutableBytes({ raw in
            CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        }) else {
            throw ImageError.unreadable(path, "could not create an RGB drawing context")
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let pixels = MLXArray(buffer, [height, width, 4]).asType(.float32) / 255.0
        return pixels[0..., 0..., 0 ..< 3].expandedDimensions(axis: 0)
    }
}


/// Ref2VA-ready pixels for a still image. Both representations originate from
/// the same decode so the encoder and Visual VAE see identical pixels.
struct H3DecodedImage {
    /// `[1, H, W, 3]`, RGB in `[0, 1]`, for the H3 Encoder.
    let encoderPixels: MLXArray
    /// `[1, 3, 1, H, W]`, RGB in `[-1, 1]`, for the Visual VAE.
    let visualVAEPixels: MLXArray
}

/// Ref2VA-ready video frames. `sourceFrameRate` is retained for reference
/// timing; `frames` have been resampled to H3's 24 FPS conditioning rate.
struct H3DecodedVideo {
    /// Each frame is `[1, H, W, 3]`, RGB in `[0, 1]`, for the H3 Encoder.
    let frames: [MLXArray]
    /// `[1, 3, F, H, W]`, RGB in `[-1, 1]`, for the Visual VAE.
    let visualVAEPixels: MLXArray
    let sourceFrameRate: Double
    let frameRate: Int
    /// The video's own audio track, normalized when one is present.
    let audio: H3DecodedAudio?
}

/// Ref2VA-ready stereo audio. `sourceSampleRate` retains the file's reported
/// rate, while `samples` are normalized to the H3 Audio VAE's 32 kHz input.
struct H3DecodedAudio {
    /// `[left, right]` floating-point PCM channels at `sampleRate`.
    let samples: [[Float]]
    let sourceSampleRate: Double
    let sampleRate: Int
}

enum H3DecodedReference {
    case image(H3DecodedImage)
    case video(H3DecodedVideo)
    case audio(H3DecodedAudio)
}

/// Local media inspection and decoding for Ref2VA. The public request API
/// carries ordered URLs; media kind is resolved here from each URL.
extension H3IO {
    private static let minimumDuration = 2.0
    private static let maximumDuration = 15.0
    private static let frameRate = H3Configuration.presetH3BaseRef2VA.frameRate
    private static let sampleRate = H3Configuration.presetH3BaseRef2VA.audioSampleRate

    static func inspect(_ url: URL) throws -> H3ReferenceMediaKind {
        guard url.isFileURL,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw H3EvaluatorError.unreadable(
                path: url.path,
                reason: "reference file does not exist or is not readable")
        }

        guard let type = UTType(filenameExtension: url.pathExtension) else {
            throw H3EvaluatorError.unreadable(
                path: url.path,
                reason: "file extension does not identify a supported image, video, or audio type")
        }

        if type.conforms(to: .image) {
            _ = try H3IO.imageSize(at: url.path)
            return .image
        } else if type.conforms(to: .movie) || type.conforms(to: .video) {
            let asset = AVURLAsset(url: url)
            guard !asset.tracks(withMediaType: .video).isEmpty else {
                throw H3EvaluatorError.unreadable(path: url.path, reason: "no decodable video track")
            }
            _ = try validateDuration(of: asset, path: url.path, kind: "video")
            return .video
        } else if type.conforms(to: .audio) {
            let asset = AVURLAsset(url: url)
            guard !asset.tracks(withMediaType: .audio).isEmpty else {
                throw H3EvaluatorError.unreadable(path: url.path, reason: "no decodable audio track")
            }
            _ = try validateDuration(of: asset, path: url.path, kind: "audio")
            return .audio
        }
        throw H3EvaluatorError.unreadable(
            path: url.path,
            reason: "unsupported reference media type")
    }

    static func decode(
        _ url: URL,
        fit: (width: Int, height: Int)? = nil
    ) throws -> H3DecodedReference {
        switch try inspect(url) {
        case .image:
            return H3DecodedReference.image(try image(at: url, fit: fit))
        case .video:
            return H3DecodedReference.video(try video(at: url, fit: fit))
        case .audio:
            return H3DecodedReference.audio(try audio(at: url))
        }
    }

    private static func image(
        at url: URL,
        fit: (width: Int, height: Int)?
    ) throws -> H3DecodedImage {
        let size = try fittedImageSize(at: url, fit: fit)
        let encoderPixels = try H3IO.imageHWC(at: url.path, width: size.width, height: size.height)
        let visualVAEPixels = (encoderPixels * 2.0 - 1.0)
            .squeezed(axis: 0)
            .transposed(2, 0, 1)
            .expandedDimensions(axes: [0, 2])
        return H3DecodedImage(encoderPixels: encoderPixels, visualVAEPixels: visualVAEPixels)
    }

    private static func video(
        at url: URL,
        fit: (width: Int, height: Int)?
    ) throws -> H3DecodedVideo {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw H3EvaluatorError.unreadable(path: url.path, reason: "no decodable video track")
        }
        let duration = try validateDuration(of: asset, path: url.path, kind: "video")
        let size = try fittedVideoSize(track: track, path: url.path, fit: fit)
        let reportedFrameRate = reportedFrameRate(for: track)
        let decodedAudio = try asset.tracks(withMediaType: .audio).first.map {
            try audio(from: asset, track: $0, path: url.path)
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw H3EvaluatorError.unreadable(path: url.path, reason: "could not create video decoder: \(error.localizedDescription)")
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
            ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw H3EvaluatorError.unreadable(path: url.path, reason: "video decoder cannot read this track")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw H3EvaluatorError.unreadable(
                path: url.path,
                reason: "video decoder could not start: \(reader.error?.localizedDescription ?? "unknown error")")
        }

        let targetFrameCount = max(1, Int((duration * Double(frameRate)).rounded(.down)))
        let targetInterval = 1.0 / Double(frameRate)
        var nextTargetTime = 0.0
        var latestFrame: MLXArray?
        var frames: [MLXArray] = []

        while let sample = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sample) }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let currentFrame = try rgbFrame(from: pixelBuffer, path: url.path)
            latestFrame = currentFrame
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard timestamp.isFinite else { continue }
            while nextTargetTime <= timestamp + targetInterval / 2, frames.count < targetFrameCount {
                frames.append(currentFrame)
                nextTargetTime += targetInterval
            }
        }

        guard reader.status == .completed else {
            throw H3EvaluatorError.unreadable(
                path: url.path,
                reason: "video decoding failed: \(reader.error?.localizedDescription ?? "unknown error")")
        }
        guard let latestFrame else {
            throw H3EvaluatorError.unreadable(path: url.path, reason: "video decoder produced no frames")
        }
        while frames.count < targetFrameCount {
            frames.append(latestFrame)
        }

        let allFrames = concatenated(frames, axis: 0)
        let visualVAEPixels = (allFrames * 2.0 - 1.0)
            .transposed(3, 0, 1, 2)
            .expandedDimensions(axis: 0)
        return H3DecodedVideo(
            frames: frames,
            visualVAEPixels: visualVAEPixels,
            sourceFrameRate: reportedFrameRate,
            frameRate: frameRate,
            audio: decodedAudio)
    }

    private static func audio(at url: URL) throws -> H3DecodedAudio {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw H3EvaluatorError.unreadable(path: url.path, reason: "could not open audio decoder: \(error.localizedDescription)")
        }
        let sourceFormat = file.processingFormat
        let reportedSampleRate = file.fileFormat.sampleRate
        guard sourceFormat.sampleRate > 0, file.length > 0 else {
            throw H3EvaluatorError.unreadable(path: url.path, reason: "audio stream has no samples")
        }
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw H3EvaluatorError.unreadable(path: url.path, reason: "could not allocate audio decode buffer")
        }
        do {
            try file.read(into: sourceBuffer)
        } catch {
            throw H3EvaluatorError.unreadable(path: url.path, reason: "audio decoding failed: \(error.localizedDescription)")
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 2,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw H3EvaluatorError.unreadable(path: url.path, reason: "could not create stereo 32 kHz audio converter")
        }
        let targetCapacity = AVAudioFrameCount(
            ceil(Double(sourceBuffer.frameLength) * Double(sampleRate) / sourceFormat.sampleRate)
        ) + 1
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
            throw H3EvaluatorError.unreadable(path: url.path, reason: "could not allocate normalized audio buffer")
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: targetBuffer, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return sourceBuffer
        }
        guard status != .error, conversionError == nil,
              let channels = targetBuffer.floatChannelData,
              targetBuffer.frameLength > 0 else {
            throw H3EvaluatorError.unreadable(
                path: url.path,
                reason: "audio conversion failed: \(conversionError?.localizedDescription ?? "no output samples")")
        }
        let sampleCount = Int(targetBuffer.frameLength)
        let samples = (0 ..< 2).map { channel in
            Array(UnsafeBufferPointer(start: channels[channel], count: sampleCount))
        }
        return H3DecodedAudio(
            samples: samples,
            sourceSampleRate: reportedSampleRate,
            sampleRate: sampleRate)
    }

    private static func audio(
        from asset: AVAsset,
        track: AVAssetTrack,
        path: String
    ) throws -> H3DecodedAudio {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw H3EvaluatorError.unreadable(path: path, reason: "could not create video audio decoder: \(error.localizedDescription)")
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
        guard reader.canAdd(output) else {
            throw H3EvaluatorError.unreadable(path: path, reason: "audio decoder cannot read this video track")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw H3EvaluatorError.unreadable(
                path: path,
                reason: "audio decoder could not start: \(reader.error?.localizedDescription ?? "unknown error")")
        }

        var left: [Float] = []
        var right: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sample) }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { continue }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            guard byteCount > 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: byteCount)
            let copyStatus = bytes.withUnsafeMutableBytes { destination in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: destination.baseAddress!)
            }
            guard copyStatus == kCMBlockBufferNoErr else {
                throw H3EvaluatorError.unreadable(path: path, reason: "could not read decoded audio samples")
            }
            let frameCount = byteCount / (MemoryLayout<Float>.stride * 2)
            bytes.withUnsafeBytes { samples in
                for frame in 0 ..< frameCount {
                    let offset = frame * MemoryLayout<Float>.stride * 2
                    left.append(samples.loadUnaligned(fromByteOffset: offset, as: Float.self))
                    right.append(samples.loadUnaligned(
                        fromByteOffset: offset + MemoryLayout<Float>.stride,
                        as: Float.self))
                }
            }
        }
        guard reader.status == .completed, !left.isEmpty else {
            throw H3EvaluatorError.unreadable(
                path: path,
                reason: "video audio decoding failed: \(reader.error?.localizedDescription ?? "no output samples")")
        }
        return H3DecodedAudio(
            samples: [left, right],
            sourceSampleRate: reportedSampleRate(for: track),
            sampleRate: sampleRate)
    }

    private static func validateDuration(of asset: AVAsset, path: String, kind: String) throws -> Double {
        let seconds = asset.duration.seconds
        guard seconds.isFinite, (minimumDuration ... maximumDuration).contains(seconds) else {
            throw H3EvaluatorError.invalidRequest(
                rule: "\(kind) reference duration out of range",
                detail: "\(seconds.isFinite ? String(format: "%.3f", seconds) : "unknown") seconds; Ref2VA accepts 2–15 seconds",
                remedy: "trim or replace \(kind) reference \(path) with a 2–15 second clip.")
        }
        return seconds
    }

    private static func fittedImageSize(
        at url: URL,
        fit: (width: Int, height: Int)?
    ) throws -> (width: Int, height: Int) {
        if let fit { return fit }
        let size = try H3IO.imageSize(at: url.path)
        return aligned(size)
    }

    private static func fittedVideoSize(
        track: AVAssetTrack,
        path: String,
        fit: (width: Int, height: Int)?
    ) throws -> (width: Int, height: Int) {
        if let fit { return fit }
        let naturalSize = track.naturalSize
        let size = (width: Int(abs(naturalSize.width)), height: Int(abs(naturalSize.height)))
        guard size.width > 0, size.height > 0 else {
            throw H3EvaluatorError.unreadable(path: path, reason: "video has no pixel dimensions")
        }
        return aligned(size)
    }

    private static func aligned(_ size: (width: Int, height: Int)) -> (width: Int, height: Int) {
        (max(32, size.width / 32 * 32), max(32, size.height / 32 * 32))
    }

    private static func reportedFrameRate(for track: AVAssetTrack) -> Double {
        let nominalFrameRate = Double(track.nominalFrameRate)
        guard nominalFrameRate > 0 else { return Double(frameRate) }
        return nominalFrameRate
    }

    private static func reportedSampleRate(for track: AVAssetTrack) -> Double {
        guard let description = track.formatDescriptions.first else {
            return Double(sampleRate)
        }
        // This helper is called only for an AVMediaType.audio track.
        let audioDescription = description as! CMAudioFormatDescription
        guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(audioDescription),
              streamDescription.pointee.mSampleRate > 0 else {
            return Double(sampleRate)
        }
        return streamDescription.pointee.mSampleRate
    }

    private static func rgbFrame(from pixelBuffer: CVPixelBuffer, path: String) throws -> MLXArray {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            throw H3EvaluatorError.unreadable(path: path, reason: "video decoder did not produce BGRA pixels")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw H3EvaluatorError.unreadable(path: path, reason: "video frame has no pixel buffer")
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let source = baseAddress.assumingMemoryBound(to: UInt8.self)
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for row in 0 ..< height {
            let sourceRow = source.advanced(by: row * sourceBytesPerRow)
            let destinationOffset = row * width * 3
            for column in 0 ..< width {
                let sourceOffset = column * 4
                let destination = destinationOffset + column * 3
                rgb[destination] = sourceRow[sourceOffset + 2]
                rgb[destination + 1] = sourceRow[sourceOffset + 1]
                rgb[destination + 2] = sourceRow[sourceOffset]
            }
        }
        return (MLXArray(rgb, [height, width, 3]).asType(.float32) / 255.0)
            .expandedDimensions(axis: 0)
    }

    private static func deinterleave(_ waveform: MLXArray) -> [[Float]] {
        let length = waveform.dim(2)
        let flat = waveform
            .reshaped([waveform.dim(0) * waveform.dim(1), length])
            .asType(.float32)
            .asArray(Float.self)
        return (0 ..< min(2, waveform.dim(1))).map {
            Array(flat[($0 * length) ..< (($0 + 1) * length)])
        }
    }
}
