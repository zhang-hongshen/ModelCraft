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
                    
                    let recognizedText = request.results?.compactMap { observation in
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
}
