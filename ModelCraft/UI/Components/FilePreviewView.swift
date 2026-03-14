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

#if os(iOS)

import PDFKit

struct PDFPreview: UIViewRepresentable {

    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}

}

#endif

#if os(macOS)

import PDFKit

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

#endif

#if os(iOS)

import QuickLook

struct QuickLookPreview: UIViewControllerRepresentable {

    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {

        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    class Coordinator: NSObject, QLPreviewControllerDataSource {

        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            url as QLPreviewItem
        }
    }
}

#endif

#if os(macOS)
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

#endif
