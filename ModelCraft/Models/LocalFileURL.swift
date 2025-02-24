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
        print("type = ", type)
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
        } else if type.conforms(to: .video) || type.conforms(to: .quickTimeMovie) {
            return try await readVideoContent()
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
                     
                    let result = request.results?.compactMap { observation in
                        observation.topCandidates(1).map { $0.string }
                    }.flatMap { $0 }
                    continuation.resume(returning: result ?? [])
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
    
    private func readVideoContent() async throws -> String {
        try await extractIFrame()
        return ""
    }
    
    private func extractIFrame() async throws {
        let asset = AVAsset(url: self)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            print("No video track found")
            return
        }

        let reader = try! AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        
        reader.startReading()

        var iFrameTimes: [CMTime] = []
        
        while let sampleBuffer = output.copyNextSampleBuffer() {
        
            // identify whether it is i-frame
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                         createIfNecessary: false) as? [[CFString: Any]],
                let attachment = attachments.first,
                let dependsOnOthers = attachment[kCMSampleAttachmentKey_DependsOnOthers] as? Bool, !dependsOnOthers {
                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    iFrameTimes.append(pts)
                }
        }
        reader.cancelReading()

        let imageGenerator = AVAssetImageGenerator(asset: asset)
        
        let picturesURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        print("pictures:", picturesURL.path())
        for time in iFrameTimes {
            imageGenerator.generateCGImageAsynchronously(for: time) { cgImageOrNil, time, errorOrNil in
                print("generateCGImageAsynchronously completed")
                if let error = errorOrNil {
                    print("Failed to extract image at \(time.seconds)s: \(error)")
                    return
                }
                guard let cgImage = cgImageOrNil else {
                    return
                }
                let image = PlatformImage(cgImage: cgImage, size: .zero)
                print("Extracted I-frame at \(time.seconds)s")
               
                let fileName = "frame_\(CMTimeGetSeconds(time)).png"
                do {
                    try image.save(to: picturesURL.appending(path: fileName))
                } catch {
                    print("Failed to save image: \(error)")
                }
            }
        }
    }
    
}
