//
//  QuickEntryView.swift
//  ModelCraft
//

import SwiftUI
import KeyboardShortcuts
import AppKit
import UniformTypeIdentifiers

/// The Quick Entry panel's content: the request field with voice input, and the context read
/// from the app the user was in, each item removable before sending.
struct QuickEntryView: View {

    let sourceApp: NSRunningApplication?
    let selection: QuickEntryContext
    let onSubmit: (String, [URL]) -> Void
    let onClose: () -> Void

    @State private var request = ""
    @State private var context = QuickEntryContext()
    @State private var isCapturing = true
    @State private var images: [URL] = []
    @State private var imageError: String?
    @State private var hasSubmitted = false
    @State private var voiceInputTask: Task<Void, Never>?
    @State private var voiceInputError: String?
    @FocusState private var isFieldFocused: Bool
    @Environment(\.controlActiveState) private var controlActiveState

    @Environment(STTService.self) private var sttService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)

                ZStack {
                    TextField("Ask ModelCraft", text: $request, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.title2)
                        .lineLimit(1...8)
                        .focused($isFieldFocused)
                        .onSubmit(submit)
                        .disabled(voiceInputTask != nil)
                        .opacity(voiceInputTask == nil ? 1 : 0)
                        .accessibilityHidden(voiceInputTask != nil)
                        .frame(maxHeight: voiceInputTask != nil ? 36 : nil)
                        .clipped()

                    if voiceInputTask != nil {
                        HStack {
                            Button(action: cancelVoiceInput) {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Cancel Voice Input")
                            VoiceLevelView(sttService: sttService)
                        }
                    }
                }

                if voiceInputTask != nil {
                    Button(action: sttService.stop) {
                        Image(systemName: "pause.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .disabled(sttService.state != .recording)
                    .accessibilityLabel("Stop Recording and Transcribe")
                } else if request.isEmpty {
                    Button(action: startVoiceInput) {
                        Image(systemName: "mic")
                    }
                    .buttonStyle(.borderless)
                    .font(.title2)
                    .disabled(sttService.state != .idle)
                    .help("Voice Input")
                    .accessibilityLabel("Start Voice Input")
                } else {
                    Button(action: submit) {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .disabled(isCapturing || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send Message")
                }
            }

            if let voiceInputError {
                Text(verbatim: voiceInputError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if let imageError {
                Text(verbatim: imageError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if isCapturing || context.hasItems || !images.isEmpty {
                ContextItems()
            }
        }
        .padding(16)
        .frame(minWidth: 560, idealWidth: 640, maxWidth: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .defaultFocus($isFieldFocused, true)
        .onPasteCommand(of: [.image]) { _ in
            if let image = NSImage(pasteboard: .general) {
                addImage(image)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            var accepted = false
            for url in urls where url.isFileURL {
                guard let type = UTType(filenameExtension: url.pathExtension),
                      type.conforms(to: .image), let image = NSImage(contentsOf: url)
                else { continue }
                addImage(image)
                accepted = true
            }
            return accepted
        }
        .onExitCommand {
            if voiceInputTask != nil {
                cancelVoiceInput()
            } else {
                onClose()
            }
        }
        .task(id: controlActiveState == .key) {
            guard controlActiveState == .key else { return }
            for await _ in KeyboardShortcuts.events(.keyDown, for: .voiceInput) {
                guard !Task.isCancelled, controlActiveState == .key else { return }
                toggleVoiceInput()
            }
        }
        .task {
            context = selection
            guard let sourceApp else {
                isCapturing = false
                return
            }
            let captured = await QuickEntryContext.capture(from: sourceApp, selection: selection)
            guard !Task.isCancelled else { return }
            context.files = captured.files
            context.page = captured.page
            isCapturing = false
        }
        .onDisappear {
            cancelVoiceInput()
            if !hasSubmitted {
                for url in images { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    @ViewBuilder
    private func ContextItems() -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                if isCapturing {
                    ProgressView()
                        .controlSize(.small)
                }
                ForEach(context.files, id: \.self) { url in
                    ContextItem(
                        icon: Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)),
                        title: url.lastPathComponent
                    ) {
                        context.files.removeAll { $0 == url }
                    }
                }
                if let page = context.page {
                    ContextItem(icon: sourceAppIcon, title: page.title) {
                        context.page = nil
                    }
                }
                if let selectedText = context.selectedText {
                    ContextItem(icon: Image(systemName: "text.quote"), title: selectedText) {
                        context.selectedText = nil
                    }
                }
                if let image = context.image {
                    ContextItem(icon: Image(systemName: "link"), title: image.title) {
                        context.image = nil
                    }
                }
                ForEach(images, id: \.self) { url in
                    ContextItem(
                        icon: Image(nsImage: NSImage(contentsOf: url) ?? NSImage()),
                        title: String(localized: "Image")
                    ) {
                        images.removeAll { $0 == url }
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
        }
        .scrollIndicators(.never)
    }

    private var sourceAppIcon: Image {
        if let icon = sourceApp?.icon {
            Image(nsImage: icon)
        } else {
            Image(systemName: "globe")
        }
    }

    private func submit() {
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, voiceInputTask == nil, !isCapturing else { return }
        hasSubmitted = true
        onSubmit(context.message(for: request), images)
    }

    private func addImage(_ image: NSImage) {
        do {
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let data = bitmap.representation(using: .png, properties: [:])
            else { throw CocoaError(.fileReadCorruptFile) }
            try FileManager.default.createDirectory(at: Message.draftDirectory, withIntermediateDirectories: true)
            let url = Message.draftDirectory.appendingPathComponent("image-\(UUID().uuidString).png")
            try data.write(to: url, options: .atomic)
            images.append(url)
            imageError = nil
        } catch {
            imageError = error.localizedDescription
        }
    }

    private func toggleVoiceInput() {
        if voiceInputTask == nil {
            startVoiceInput()
        } else if sttService.state == .recording {
            sttService.stop()
        }
    }

    /// Records until stopped and appends the transcript to the request, where it can be
    /// edited before sending.
    private func startVoiceInput() {
        guard voiceInputTask == nil, sttService.state == .idle else { return }
        voiceInputError = nil
        isFieldFocused = false
        voiceInputTask = Task {
            defer {
                voiceInputTask = nil
                isFieldFocused = true
            }
            do {
                let text = try await sttService.record()
                try Task.checkCancellation()
                if !text.isEmpty {
                    request = request.isEmpty ? text : request + " " + text
                }
            } catch is CancellationError {
                // Cancelled by the user or by closing the panel.
            } catch {
                guard !Task.isCancelled else { return }
                voiceInputError = error.localizedDescription
            }
        }
    }

    private func cancelVoiceInput() {
        voiceInputTask?.cancel()
        if voiceInputTask != nil { sttService.cancel() }
    }
}

/// One piece of context, shown with its icon and removable before sending.
private struct ContextItem: View {

    let icon: Image
    let title: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            icon
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 200, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove")
        }
        .font(.callout)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(.quaternary, in: Capsule())
    }
}

private extension QuickEntryContext {
    var hasItems: Bool {
        !files.isEmpty || page != nil || selectedText != nil || image != nil
    }
}
