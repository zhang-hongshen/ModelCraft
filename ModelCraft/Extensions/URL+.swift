//
//  URL+.swift
//  ModelCraft
//
//  Created by Hongshen on 25/2/24.
//

import Foundation
import AVFoundation
import PDFKit
import Vision
import UniformTypeIdentifiers

import MLXAudioSTT
import MLXAudioCore

extension URL {

    /// The app's own folder in Application Support, named after its bundle ID.
    static let appSupportDirectory = URL.applicationSupportDirectory.appending(
        path: Bundle.main.bundleIdentifier!,
        directoryHint: .isDirectory)

    /// Moves the `Application Support/ModelCraft` folder used before the app's folder was
    /// named after its bundle ID.
    static func moveLegacyAppSupportDirectory() {
        let fileManager = FileManager.default
        let legacy = URL.applicationSupportDirectory.appending(path: "ModelCraft", directoryHint: .isDirectory)
        guard fileManager.fileExists(at: legacy), !fileManager.fileExists(at: appSupportDirectory) else {
            return
        }
        try? fileManager.moveDirectory(at: legacy, to: appSupportDirectory)
    }
    
    func readContent() async throws -> String {
        guard isFileURL, let type = UTType(filenameExtension: pathExtension) else { return "" }
        if type.conforms(to: .pdf) {
            return readPDFContent()
        } else if type.conforms(to: .audio) {
            return try await readAudioContent()
        }
        return ""
    }
    
    private func readPDFContent() -> String {
        guard isFileURL, let type = UTType(filenameExtension: pathExtension) else { return "" }
        if !type.conforms(to: .pdf) {
            return ""
        }
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
    
    private func readAudioContent() async throws -> String {
        guard isFileURL, let type = UTType(filenameExtension: pathExtension) else { return "" }
        if !type.conforms(to: .audio) {
            return ""
        }
        let sttModel = try await STTService.loadModel(id: "mlx-community/Qwen3-ASR-0.6B-4bit")
        let (_, audioData) = try loadAudioArray(from: self)
        return sttModel.generate(audio: audioData).text
    }
    
    
}
