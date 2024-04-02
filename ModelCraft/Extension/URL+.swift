//
//  URL+.swift
//
//
//  Created by 张鸿燊 on 25/2/2024.
//

import Foundation
import PDFKit
import UniformTypeIdentifiers

extension URL {
    
    static let ollamaBaseURL =  URL(string: "http://localhost:11434")!
    
    var isLocal: Bool {
        scheme == "file"
    }

    func readContent() throws -> String {
        guard let type = UTType(filenameExtension: pathExtension) else { return "" }
        if type.conforms(to: .pdf) {
            return readPDFContent()
        } else if type.conforms(to: .xml) {
            return XMLFile().readContent(url: self)
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
}
