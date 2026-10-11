//
//  FilePreviewView.swift
//  ModelCraft
//
//  Created by Hongshen on 9/3/26.
//

import SwiftUI
import QuickLook
import PDFKit
import UniformTypeIdentifiers

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
                    FilePathBar(fileURL: url)
                }
            }

            Spacer(minLength: 0)

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

/// Finder's path bar for the folder that contains `fileURL`. Clicking a folder opens it in
/// Finder; clicking the containing folder also selects the file.
private struct FilePathBar: NSViewRepresentable {

    let fileURL: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSPathControl {
        let pathControl = NSPathControl()
        pathControl.pathStyle = .standard
        pathControl.isEditable = false
        pathControl.controlSize = .small
        pathControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathControl.focusRingType = .none
        pathControl.target = context.coordinator
        pathControl.action = #selector(Coordinator.openClickedFolder(_:))
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return pathControl
    }

    func updateNSView(_ pathControl: NSPathControl, context: Context) {
        context.coordinator.fileURL = fileURL
        pathControl.url = fileURL.deletingLastPathComponent()
    }

    final class Coordinator: NSObject {

        var fileURL: URL?

        @objc func openClickedFolder(_ sender: NSPathControl) {
            guard let folderURL = sender.clickedPathItem?.url else { return }
            if let fileURL,
               folderURL.standardizedFileURL.path
                == fileURL.deletingLastPathComponent().standardizedFileURL.path {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            } else {
                NSWorkspace.shared.open(folderURL)
            }
        }
    }
}

struct FilePreviewView: View {
    
    let url: URL
    
    var body: some View {
        switch url.pathExtension.lowercased() {
        case "pdf":
            PDFPreview(url: url)
        default:
            if hasKnownPreview {
                QuickLookPreview(url: url)
            } else {
                PlainTextPreview(url: url)
            }
        }
    }

    /// Quick Look only shows an icon for a type that no app declares as text, such as
    /// `.ipynb`; those files get a plain-text preview when they are UTF-8 text.
    private var hasKnownPreview: Bool {
        guard let type = UTType(filenameExtension: url.pathExtension),
              !type.isDynamic else {
            return false
        }
        return [UTType.text, .image, .audiovisualContent, .compositeContent, .archive]
            .contains { type.conforms(to: $0) }
    }
}

private struct PlainTextPreview: View {

    let url: URL

    @State private var text: String?
    @State private var isLoaded = false

    var body: some View {
        Group {
            if let text {
                ScrollView {
                    Text(verbatim: text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else if isLoaded {
                QuickLookPreview(url: url)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            text = nil
            isLoaded = false
            text = await Self.loadText(from: url)
            isLoaded = true
        }
    }

    /// The file's contents, or `nil` when it is not UTF-8 text.
    private nonisolated static func loadText(from url: URL) async -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              !data.contains(0) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
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
