//
//  FilePreviewView.swift
//  ModelCraft
//
//  Created by Hongshen on 9/3/26.
//

import SwiftUI
import QuickLook
import PDFKit

struct FilePreviewView: View {
    
    let url: URL
    
    var body: some View {
        switch url.pathExtension.lowercased() {
        case "pdf":
            PDFPreview(url: url)
        default:
            QuickLookPreview(url: url)
        }
    }
}

struct PDFPreview: NSViewRepresentable {

    let url: URL

    func makeNSView(context: Context) -> PDFView {

        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)

        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {}

}

import QuickLookUI

struct QuickLookPreview: NSViewRepresentable {

    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {

        let view = QLPreviewView(frame: .zero)!
        view.previewItem = url as QLPreviewItem
        view.autostarts = true

        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        nsView.previewItem = url as QLPreviewItem
    }
}


#Preview {
    FilePreviewView(url: URL.documentsDirectory.appendingPathComponent("1", conformingTo: .pdf))
}
