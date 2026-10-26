//
//  ChatInputView.swift
//  ModelCraft
//
//  Created by Hongshen on 10/11/25.
//

import SwiftUI
import AppKit
import PhotosUI
import UniformTypeIdentifiers

enum ChatComposerCommand {
    case previous
    case next
    case select
    case dismiss
}

struct ChatInputView<Header: View, Content: View>: View {
    
    @Bindable var userInput: Message
    let skillNames: [String]?
    let placeholder: LocalizedStringKey
    @Binding var selectionLocation: Int
    @Binding var slashCommandLocation: Int?
    let onCommand: (ChatComposerCommand) -> Bool
    var header: () -> Header
    var trailing: () -> Content
    
    @State private var fileImporterPresented = false
    @State private var photosPickerPresented = false
    @State private var selectedImages: [PhotosPickerItem] = []
    
    init(
        userInput: Message,
        skillNames: [String]? = nil,
        placeholder: LocalizedStringKey = "Type Anything",
        selectionLocation: Binding<Int> = .constant(0),
        slashCommandLocation: Binding<Int?> = .constant(nil),
        onCommand: @escaping (ChatComposerCommand) -> Bool = { _ in false },
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder trailing: @escaping () -> Content
    ) {
        self._userInput = Bindable(userInput)
        self.skillNames = skillNames
        self.placeholder = placeholder
        self._selectionLocation = selectionLocation
        self._slashCommandLocation = slashCommandLocation
        self.onCommand = onCommand
        self.header = header
        self.trailing = trailing
    }

    init(
        userInput: Message,
        skillNames: [String]? = nil,
        placeholder: LocalizedStringKey = "Type Anything",
        selectionLocation: Binding<Int> = .constant(0),
        slashCommandLocation: Binding<Int?> = .constant(nil),
        onCommand: @escaping (ChatComposerCommand) -> Bool = { _ in false },
        @ViewBuilder trailing: @escaping () -> Content
    ) where Header == EmptyView {
        self.init(
            userInput: userInput,
            skillNames: skillNames,
            placeholder: placeholder,
            selectionLocation: selectionLocation,
            slashCommandLocation: slashCommandLocation,
            onCommand: onCommand,
            header: EmptyView.init,
            trailing: trailing)
    }
    
    var body: some View {
        MainView()
            .dropDestination(for: URL.self){ items, location in
                userInput.addFiles(items)
                return true
            }
            .fileImporter(isPresented: $fileImporterPresented,
                          allowedContentTypes: [.image, .movie],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    userInput.addFiles(urls)
                case .failure(let error):
                    debugPrint(error.localizedDescription)
                }
            }
            .photosPicker(isPresented: $photosPickerPresented, selection: $selectedImages)
            .onChange(of: selectedImages) { _, newValue in
                Task {
                    var newFiles: [URL] = []
                    for image in newValue {
                        if let url = try await image.loadTransferable(type: URL.self) {
                            newFiles.append(url)
                        }
                    }
                    userInput.addFiles(newFiles)
                }
            }
    }
}

extension ChatInputView {
    
    @ViewBuilder
    func MainView() -> some View {
        VStack(alignment: .leading) {
            header()

            if !userInput.files.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .center) {
                        ForEach(userInput.files, id: \.self) { url in
                            MessageFileView(
                                url: url,
                                onDelete: { userInput.removeFiles([url])}
                            ).frame(height: 70)
                        }
                    }
                }
            }
            
            if let skillNames {
                ZStack(alignment: .topLeading) {
                    if userInput.content.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }

                    ModelCraftTextEditor(
                        text: $userInput.content,
                        tokens: skillNames.map { "/\($0)" },
                        tokenSystemImage: "cube",
                        selectionLocation: $selectionLocation,
                        slashCommandLocation: $slashCommandLocation,
                        onCommand: onCommand)
                }
            } else {
                TextField(placeholder, text: $userInput.content, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .contentMargins(.trailing, 0, for: .scrollIndicators)
                    .scrollIndicators(.automatic)
                    .padding(.trailing, -16)
            }
            
            HStack(alignment: .center) {
                UploadButton()
                Spacer()
                trailing()
            }
        }
        .padding()
        .background(
            RoundedRectangle().fill(.surface)
        )
    }
    
    @ViewBuilder
    func UploadButton() -> some View {
        Menu {
            Button {
                fileImporterPresented = true
            } label: {
                Label("Files", systemImage: "doc.badge.plus")
            }
            
            Button {
                photosPickerPresented = true
            } label: {
                Label("Photos", systemImage: "photo.on.rectangle.angled")
            }
        } label: {
            Image(systemName: "plus")
                .font(.title3)
                .frame(width: 36, height: 36)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .help("Add Files")
    }
}

/// A plain-text editor that renders each occurrence of `tokens` in the accent color with
/// a leading icon. The icons are display-only; `text` and `selectionLocation` never
/// include them.
private struct ModelCraftTextEditor: NSViewRepresentable {

    /// Matches the body font of sent messages. The text view's own `font` reflects its
    /// first character, so it is never read back as the source of truth.
    static let font = NSFont.systemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize)

    @Binding var text: String
    let tokens: [String]
    let tokenSystemImage: String
    @Binding var selectionLocation: Int
    @Binding var slashCommandLocation: Int?
    let onCommand: (ChatComposerCommand) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: .greatestFiniteMagnitude as CGFloat)
        scrollView.documentView = textView

        context.coordinator.render(
            text,
            tokens: tokens,
            selectionLocation: selectionLocation,
            in: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        context.coordinator.updateIfNeeded(textView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSScrollView,
        context: Context
    ) -> CGSize? {
        // SwiftUI also proposes an infinite width to measure the maximum size; sizing
        // the text view to it is invalid geometry, so only a finite width is measured.
        guard let width = proposal.width, width.isFinite,
              let textView = nsView.documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return nil
        }

        textView.frame.size.width = width
        textContainer.containerSize = NSSize(
            width: width,
            height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)

        let lineHeight = layoutManager.defaultLineHeight(for: Self.font)
        let contentHeight = ceil(layoutManager.usedRect(for: textContainer).height)
        return CGSize(
            width: width,
            height: min(max(contentHeight, lineHeight), lineHeight * 3))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: ModelCraftTextEditor
        private var isRendering = false
        private var renderedTokens: [String] = []
        private var tokenRegex: NSRegularExpression?

        init(parent: ModelCraftTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isRendering,
                  let textView = notification.object as? NSTextView else {
                return
            }
            synchronize(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isRendering,
                  let textView = notification.object as? NSTextView else {
                return
            }
            updateSelection(from: textView)
        }

        func textView(
            _ textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            // Return sends, so Command-Return is the way to start a new line.
            if let event = NSApp.currentEvent,
               event.type == .keyDown,
               event.keyCode == 36 || event.keyCode == 76,
               event.modifierFlags.contains(.command) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            let command: ChatComposerCommand?
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                command = .previous
            case #selector(NSResponder.moveDown(_:)):
                command = .next
            case #selector(NSResponder.insertNewline(_:)):
                command = .select
            case #selector(NSResponder.cancelOperation(_:)):
                command = .dismiss
            default:
                command = nil
            }
            guard let command else { return false }
            return parent.onCommand(command)
        }

        func updateIfNeeded(_ textView: NSTextView) {
            // Re-rendering replaces the text storage, which would discard an input
            // method's in-progress composition.
            guard !textView.hasMarkedText() else { return }
            updateRegexIfNeeded(parent.tokens)
            let source = sourceString(from: textView.attributedString())
            let displaySelection = displayLocation(
                for: parent.selectionLocation,
                in: parent.text)
            if source != parent.text
                || renderedTokens != parent.tokens
                || textView.selectedRange().location != displaySelection {
                render(
                    parent.text,
                    tokens: parent.tokens,
                    selectionLocation: parent.selectionLocation,
                    in: textView)
            }
        }

        func render(
            _ source: String,
            tokens: [String],
            selectionLocation: Int,
            in textView: NSTextView
        ) {
            isRendering = true
            defer { isRendering = false }

            updateRegexIfNeeded(tokens)
            let baseAttributes = Self.textAttributes
            let attributed = NSMutableAttributedString(
                string: source,
                attributes: baseAttributes)
            let matches = tokenMatches(in: source)

            for match in matches.reversed() {
                attributed.addAttribute(
                    .foregroundColor,
                    value: NSColor(resource: .accent),
                    range: match.range)
                attributed.insert(tokenIcon(), at: match.range.location)
            }

            textView.textStorage?.setAttributedString(attributed)
            textView.typingAttributes = baseAttributes
            let displaySelection = min(
                displayLocation(for: selectionLocation, in: source),
                attributed.length)
            textView.setSelectedRange(NSRange(location: displaySelection, length: 0))
            textView.scrollRangeToVisible(NSRange(location: displaySelection, length: 0))
            renderedTokens = tokens
        }

        private func synchronize(_ textView: NSTextView) {
            // Composed text is published once the input method commits it.
            guard !textView.hasMarkedText() else { return }
            let source = sourceString(from: textView.attributedString())
            let sourceSelection = sourceLocation(
                for: textView.selectedRange().location,
                in: textView.attributedString())
            parent.text = source
            parent.selectionLocation = sourceSelection
            parent.slashCommandLocation = slashLocation(
                in: source,
                selectionLocation: sourceSelection,
                hasSelection: textView.selectedRange().length > 0)
            render(
                source,
                tokens: parent.tokens,
                selectionLocation: sourceSelection,
                in: textView)
        }

        private func updateSelection(from textView: NSTextView) {
            guard !textView.hasMarkedText() else { return }
            let attributed = textView.attributedString()
            let source = sourceString(from: attributed)
            let sourceSelection = sourceLocation(
                for: textView.selectedRange().location,
                in: attributed)
            parent.selectionLocation = sourceSelection
            parent.slashCommandLocation = slashLocation(
                in: source,
                selectionLocation: sourceSelection,
                hasSelection: textView.selectedRange().length > 0)
        }

        private func updateRegexIfNeeded(_ tokens: [String]) {
            guard renderedTokens != tokens else { return }
            let alternatives = tokens
                .sorted { $0.count > $1.count }
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "|")
            tokenRegex = alternatives.isEmpty
                ? nil
                : try? NSRegularExpression(
                    pattern: "(?:\(alternatives))(?![A-Za-z0-9-])")
        }

        private func tokenMatches(in source: String) -> [NSTextCheckingResult] {
            tokenRegex?.matches(
                in: source,
                range: NSRange(location: 0, length: (source as NSString).length)) ?? []
        }

        private func tokenIcon() -> NSAttributedString {
            let attachment = NSTextAttachment()
            attachment.image = NSImage(
                systemSymbolName: parent.tokenSystemImage,
                accessibilityDescription: nil)?.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(
                        paletteColors: [NSColor(resource: .accent)]))
            attachment.bounds = CGRect(x: 0, y: -2, width: 14, height: 14)
            attachment.lineLayoutPadding = 1

            let icon = NSMutableAttributedString(attachment: attachment)
            icon.append(NSAttributedString(string: " "))
            icon.addAttribute(
                .tokenIcon,
                value: true,
                range: NSRange(location: 0, length: icon.length))
            return icon
        }

        private static let textAttributes: [NSAttributedString.Key: Any] = [
            .font: ModelCraftTextEditor.font,
            .foregroundColor: NSColor.labelColor,
        ]

        private func sourceString(from attributed: NSAttributedString) -> String {
            let source = NSMutableAttributedString(attributedString: attributed)
            var iconRanges: [NSRange] = []
            source.enumerateAttribute(
                .tokenIcon,
                in: NSRange(location: 0, length: source.length)) { value, range, _ in
                    if value != nil {
                        iconRanges.append(range)
                    }
                }
            for range in iconRanges.reversed() {
                source.deleteCharacters(in: range)
            }
            return source.string
        }

        private func sourceLocation(
            for displayLocation: Int,
            in attributed: NSAttributedString
        ) -> Int {
            let prefixLength = min(displayLocation, attributed.length)
            var iconLength = 0
            attributed.enumerateAttribute(
                .tokenIcon,
                in: NSRange(location: 0, length: prefixLength)) { value, range, _ in
                    if value != nil {
                        iconLength += range.length
                    }
                }
            return prefixLength - iconLength
        }

        private func displayLocation(for sourceLocation: Int, in source: String) -> Int {
            let clampedLocation = min(sourceLocation, (source as NSString).length)
            let insertedIconLength = tokenMatches(in: source).reduce(into: 0) { length, match in
                if match.range.location < clampedLocation {
                    length += 2
                }
            }
            return clampedLocation + insertedIconLength
        }

        private func slashLocation(
            in source: String,
            selectionLocation: Int,
            hasSelection: Bool
        ) -> Int? {
            let text = source as NSString
            guard !hasSelection,
                  selectionLocation > 0,
                  selectionLocation <= text.length,
                  text.substring(with: NSRange(
                    location: selectionLocation - 1,
                    length: 1)) == "/" else {
                return nil
            }
            return selectionLocation - 1
        }
    }
}

private extension NSAttributedString.Key {
    static let tokenIcon = NSAttributedString.Key(
        "ModelCraftTextEditorTokenIcon")
}

#if DEBUG
#Preview(traits: .preview) {
    ChatInputView(
        userInput: Message(chat: .preview),
        trailing: {})
}
#endif
