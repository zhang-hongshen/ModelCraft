//
//  URL+.swift
//  ModelCraft
//
//  Created by Hongshen on 25/2/2024.
//

import Foundation
import AVFoundation
import PDFKit
import Vision
import UniformTypeIdentifiers

import MLXAudioSTT
import MLXAudioCore

extension URL {
    
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
        let sttModel = try await Qwen3ASRModel.fromPretrained("mlx-community/Qwen3-ASR-0.6B-4bit")
        let (_, audioData) = try loadAudioArray(from: self)
        return sttModel.generate(audio: audioData).text
    }
}
