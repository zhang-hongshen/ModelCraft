//
//  FilePreviewView.swift
//  ModelCraft
//
//  Created by Hongshen on 9/3/26.
//

import SwiftUI
import QuickLook
import PDFKit

enum FilePreviewLink {

    private static let scheme = "modelcraft-file-preview"

    static func url(for path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url
    }

    static func path(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "path" })?
            .value
    }
}

struct FileInspectorView: View {

    let url: URL?
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            FileInspectorHeader(url: url, isPresented: $isPresented)
            Divider()

            if let url {
                FilePreviewView(url: url)
            } else {
                ContentUnavailableView(
                    "No File Selected",
                    systemImage: "doc.text.magnifyingglass"
                )
            }
        }
        .inspectorColumnWidth(min: 280, ideal: 420, max: 700)
    }
}

private struct FileInspectorHeader: View {

    let url: URL?
    @Binding var isPresented: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(url?.lastPathComponent ?? String(localized: "File Preview"))
                    .font(.headline)
                    .lineLimit(1)

                if let url {
                    Text(url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(url.path)
                }
            }

            Spacer()

            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close File Preview")
            .accessibilityLabel("Close File Preview")
        }
        .padding()
    }
}

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
