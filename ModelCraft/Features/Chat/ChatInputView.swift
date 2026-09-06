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

struct ChatInputView<Content: View>: View {
    
    @Bindable var userInput: Message
    let skillNames: [String]?
    @Binding var selectionLocation: Int
    @Binding var slashCommandLocation: Int?
    let onCommand: (ChatComposerCommand) -> Bool
    var trailing: () -> Content
    
    @State private var fileImporterPresented = false
    @State private var photosPickerPresented = false
    @State private var selectedImages: [PhotosPickerItem] = []
    
    init(
        userInput: Message,
        skillNames: [String]? = nil,
        selectionLocation: Binding<Int> = .constant(0),
        slashCommandLocation: Binding<Int?> = .constant(nil),
        onCommand: @escaping (ChatComposerCommand) -> Bool = { _ in false },
        @ViewBuilder trailing: @escaping () -> Content
    ) {
        self._userInput = Bindable(userInput)
        self.skillNames = skillNames
        self._selectionLocation = selectionLocation
        self._slashCommandLocation = slashCommandLocation
        self.onCommand = onCommand
        self.trailing = trailing
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
                        Text("Type Anything")
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }

                    SkillComposerTextEditor(
                        text: $userInput.content,
                        skillNames: skillNames,
                        selectionLocation: $selectionLocation,
                        slashCommandLocation: $slashCommandLocation,
                        onCommand: onCommand)
                }
            } else {
                TextField("Type Anything", text: $userInput.content, axis: .vertical)
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
            RoundedRectangle().fill(.background)
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

private struct SkillComposerTextEditor: NSViewRepresentable {

    @Binding var text: String
    let skillNames: [String]
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
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
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
            skillNames: skillNames,
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
        guard let width = proposal.width,
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

        let font = textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        let contentHeight = ceil(layoutManager.usedRect(for: textContainer).height)
        return CGSize(
            width: width,
            height: min(max(contentHeight, lineHeight), lineHeight * 3))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: SkillComposerTextEditor
        private var isRendering = false
        private var renderedSkillNames: [String] = []
        private var skillRegex: NSRegularExpression?

        init(parent: SkillComposerTextEditor) {
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
            updateRegexIfNeeded(parent.skillNames)
            let source = sourceString(from: textView.attributedString())
            let displaySelection = displayLocation(
                for: parent.selectionLocation,
                in: parent.text)
            if source != parent.text
                || renderedSkillNames != parent.skillNames
                || textView.selectedRange().location != displaySelection {
                render(
                    parent.text,
                    skillNames: parent.skillNames,
                    selectionLocation: parent.selectionLocation,
                    in: textView)
            }
        }

        func render(
            _ source: String,
            skillNames: [String],
            selectionLocation: Int,
            in textView: NSTextView
        ) {
            isRendering = true
            defer { isRendering = false }

            updateRegexIfNeeded(skillNames)
            let baseAttributes = textAttributes(for: textView)
            let attributed = NSMutableAttributedString(
                string: source,
                attributes: baseAttributes)
            let matches = skillMatches(in: source)

            for match in matches.reversed() {
                attributed.addAttribute(
                    .foregroundColor,
                    value: NSColor.controlAccentColor,
                    range: match.range)
                attributed.insert(skillIcon(), at: match.range.location)
            }

            textView.textStorage?.setAttributedString(attributed)
            textView.typingAttributes = baseAttributes
            let displaySelection = min(
                displayLocation(for: selectionLocation, in: source),
                attributed.length)
            textView.setSelectedRange(NSRange(location: displaySelection, length: 0))
            textView.scrollRangeToVisible(NSRange(location: displaySelection, length: 0))
            renderedSkillNames = skillNames
        }

        private func synchronize(_ textView: NSTextView) {
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
            guard !textView.hasMarkedText() else { return }
            render(
                source,
                skillNames: parent.skillNames,
                selectionLocation: sourceSelection,
                in: textView)
        }

        private func updateSelection(from textView: NSTextView) {
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

        private func updateRegexIfNeeded(_ skillNames: [String]) {
            guard renderedSkillNames != skillNames else { return }
            let alternatives = skillNames
                .sorted { $0.count > $1.count }
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "|")
            skillRegex = alternatives.isEmpty
                ? nil
                : try? NSRegularExpression(
                    pattern: "/(\(alternatives))(?![A-Za-z0-9-])")
        }

        private func skillMatches(in source: String) -> [NSTextCheckingResult] {
            skillRegex?.matches(
                in: source,
                range: NSRange(location: 0, length: (source as NSString).length)) ?? []
        }

        private func skillIcon() -> NSAttributedString {
            let attachment = NSTextAttachment()
            attachment.image = NSImage(
                systemSymbolName: "cube",
                accessibilityDescription: nil)?.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(
                        paletteColors: [.controlAccentColor]))
            attachment.bounds = CGRect(x: 0, y: -2, width: 14, height: 14)
            attachment.lineLayoutPadding = 1

            let icon = NSMutableAttributedString(attachment: attachment)
            icon.append(NSAttributedString(string: " "))
            icon.addAttribute(
                .skillReferenceIcon,
                value: true,
                range: NSRange(location: 0, length: icon.length))
            return icon
        }

        private func textAttributes(for textView: NSTextView) -> [NSAttributedString.Key: Any] {
            [
                .font: textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor,
            ]
        }

        private func sourceString(from attributed: NSAttributedString) -> String {
            let source = NSMutableAttributedString(attributedString: attributed)
            var iconRanges: [NSRange] = []
            source.enumerateAttribute(
                .skillReferenceIcon,
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
                .skillReferenceIcon,
                in: NSRange(location: 0, length: prefixLength)) { value, range, _ in
                    if value != nil {
                        iconLength += range.length
                    }
                }
            return prefixLength - iconLength
        }

        private func displayLocation(for sourceLocation: Int, in source: String) -> Int {
            let clampedLocation = min(sourceLocation, (source as NSString).length)
            let insertedIconLength = skillMatches(in: source).reduce(into: 0) { length, match in
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
    static let skillReferenceIcon = NSAttributedString.Key(
        "ModelCraftSkillReferenceIcon")
}

#Preview(traits: .preview) {
    ChatInputView(
        userInput: Message(chat: .preview),
        trailing: {})
}
