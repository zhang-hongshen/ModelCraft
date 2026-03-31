//
//  URL+.swift
//  ModelCraft
//
//  Created by Hongshen on 25/2/2024.
//

import Foundation
import PDFKit
import Vision
import UniformTypeIdentifiers
import WhisperKit
import AVFoundation


extension URL {
    
    func readContent() async throws -> String {
        guard isFileURL, let type = UTType(filenameExtension: pathExtension) else { return "" }
        
        if type.conforms(to: .pdf) {
            return readPDFContent()
        } else if type.conforms(to: .xml) {
            return XMLFileParser().readContent(url: self)
        } else if type.conforms(to: .image) {
            return try await readImageContent()
        } else if type.conforms(to: .text) {
            return try String(contentsOf: self, encoding: .utf8)
        } else if type.conforms(to: .audio) {
            return try await readAudioContent()
        } else if type.conforms(to: .movie) {
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
        try await extractIFrames()
        return ""
    }
    
    private func extractIFrames() async throws -> [URL] {
        let asset = AVAsset(url: self)
        
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return []
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()

        var iFrameTimes: [CMTime] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
               let attachment = attachments.first,
               let dependsOnOthers = attachment[kCMSampleAttachmentKey_DependsOnOthers] as? Bool, !dependsOnOthers {
                iFrameTimes.append(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            }
        }
        reader.cancelReading()

        
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        
        
        let storageURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("video_frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)

        return try await withThrowingTaskGroup(of: URL?.self) { group in
            for time in iFrameTimes {
                group.addTask {
                    let (cgImage, _) = try await imageGenerator.image(at: time)
                    
                    #if canImport(AppKit)
                    let image = PlatformImage(cgImage: cgImage, size: .zero)
                    #else
                    let image = PlatformImage(cgImage: cgImage)
                    #endif
                    
                    let fileName = "frame_\(time.seconds).png"
                    let fileURL = storageURL.appendingPathComponent(fileName)
                    
                    try image.save(to: fileURL)
                    return fileURL
                }
            }

            var urls: [URL] = []
            for try await url in group {
                if let url = url { urls.append(url) }
            }
            return urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        }
    }
}
