//
//  LocalFileURL.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 25/2/2024.
//

import Foundation
import PDFKit
import Vision
import UniformTypeIdentifiers
import WhisperKit
import AVFoundation

typealias LocalFileURL = URL

extension LocalFileURL: Identifiable {
    
    public var id: Self { self }
    
    func readContent() async throws -> String {
        guard isFileURL, let type = UTType(filenameExtension: pathExtension) else { return "" }
        if type.conforms(to: .pdf) {
            return readPDFContent()
        } else if type.conforms(to: .xml) {
            return XMLFile().readContent(url: self)
        } else if type.conforms(to: .image) {
            return try await readImageContent()
        } else if type.conforms(to: .text) {
            return try String(contentsOf: self, encoding: .utf8)
        } else if type.conforms(to: .audio) {
            return try await readAudioContent()
        } else if type.conforms(to: .video) {
            
        }
        return ""
    }
    
    private func readPDFContent() -> String {
        guard let pdf = PDFDocument(url: self) else { return "" }
        var content = ""
        
        for i in 0 ..< pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            guard let pageContent = page.string else { continue }
            content.append(pageContent)
        }
        print("content, \(content)")
        return content
    }
    
    @available(macOS 10.15, *)
    private func readImageContent() async throws -> String {
        var recognizeTexts = [String]()
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, visionOS 2.0, *) {
            let request  = RecognizeTextRequest()
            let recognizeTextObservations = try await request.perform(on: self)
            recognizeTexts =  recognizeTextObservations.compactMap {
                $0.topCandidates(1).first?.string
            }
        } else {
            let requestHandler = VNImageRequestHandler(url: self)
            let request = VNRecognizeTextRequest()
            recognizeTexts = try await withCheckedThrowingContinuation { continuation in
                do {
                    try requestHandler.perform([request])
                     
                    let recognizedTexts = request.results?.compactMap { observation in
                        observation.topCandidates(1).map { $0.string }
                    }.flatMap { $0 }
                    continuation.resume(returning: recognizeTexts)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

        }
        return recognizeTexts.joined(separator: " ")
    }
    
    private func readAudioContent() async throws -> String {
        let whisperKit = try await WhisperKit(WhisperKitConfig(model: "openai_whisper-small"))
        let result = try await whisperKit.transcribe(audioPath: self.path())
        return result.map { $0.text }.joined(separator: "")
    }
    
    private func readVideoContent() -> String {
        return ""
    }
    
    private func extractIFrame() async throws {
        let asset = AVAsset(url: self)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            print("No video track found")
            return
        }

        let reader = try! AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        reader.startReading()

        var iFrameTimes: [CMTime] = []
        
        while let sampleBuffer = output.copyNextSampleBuffer() {
        
            // 判断是否是 I-Frame (关键帧)
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                         createIfNecessary: false) as? [[CFString: Any]],
                let attachment = attachments.first,
                let isKeyFrame = attachment[kCMSampleAttachmentKey_DependsOnOthers] as? Bool,
                !isKeyFrame {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                iFrameTimes.append(pts)
            }
        }
        reader.cancelReading()

        // 用 AVAssetImageGenerator 抽取 I-Frame 图片
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = .zero
        
        
        for time in iFrameTimes {
            imageGenerator.generateCGImageAsynchronously(for: time) { cgImageOrNil, time, errorOrNil in
                if let error = errorOrNil {
                    print("Failed to extract image at \(time.seconds)s: \(error)")
                    return
                }
                guard let cgImage = cgImageOrNil else {
                    return
                }
                let image = PlatformImage(cgImage: cgImage, size: .zero)
                print("Extracted I-frame at \(time.seconds)s")
                let picturesURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
                let fileName = "frame_\(CMTimeGetSeconds(time)).png"
                saveImage(image, to: picturesURL.appending(path: fileName))
            }
        }
    }
    
    
    func saveImage(_ image: Any, to url: URL) {
        #if canImport(UIKit)
        guard let uiImage = image as? UIImage,
              let pngData = uiImage.pngData() else {
            print("Failed to convert UIImage to PNG data")
            return
        }
        #elseif canImport(AppKit)
        guard let nsImage = image as? NSImage,
              let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            print("Failed to convert NSImage to PNG data")
            return
        }
        #endif

        do {
            try pngData.write(to: url)
            print("Saved image to \(url.path)")
        } catch {
            print("Failed to save image: \(error)")
        }
    }
}
