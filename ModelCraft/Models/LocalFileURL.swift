//
//  LocalFileURL.swift
//
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
    
    func readContent() throws -> String {
        guard isFileURL, let type = UTType(filenameExtension: pathExtension) else { return "" }
        if type.conforms(to: .pdf) {
            return readPDFContent()
        } else if type.conforms(to: .xml) {
            return XMLFile().readContent(url: self)
        } else if type.conforms(to: .image) {
            return try readImageContent()
        } else if type.conforms(to: .text) {
            return try String(contentsOf: self, encoding: .utf8)
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
    
    private func readImageContent() throws -> String {
        let requestHandler = VNImageRequestHandler(url: self)
        var recognizedStrings: [String] = []
        let request = VNRecognizeTextRequest { request, error in
            guard let observations =
                    request.results as? [VNRecognizedTextObservation] else {
                return
            }
            recognizedStrings = observations.compactMap { observation in
                // Return the string of the top VNRecognizedText instance.
                return observation.topCandidates(1).first?.string
            }
            debugPrint("recognizedStrings, \(recognizedStrings)")
        }
        // Perform the text-recognition request.
        try requestHandler.perform([request])
        return recognizedStrings.joined(separator: "")
    }
}
