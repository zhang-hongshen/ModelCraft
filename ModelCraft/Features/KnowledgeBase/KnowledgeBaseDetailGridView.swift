//
//  KnowledgeBaseDetailGridView.swift
//  ModelCraft
//
//  Created by Hongshen on 3/4/2024.
//

import SwiftUI

struct KnowledgeBaseDetailGridView: View {
    
    @Bindable var konwledgeBase: KnowledgeBase
    @Binding var selectedFiles: Set<LocalFileURL>
    
    @State private var columns: [GridItem] = []
    
    private let gridCellWidth: CGFloat = 80
    private let columnPadding: CGFloat = 20
    // gridCellWidth + columnPadding
    private let width: CGFloat = 100
    
    private var files: [LocalFileURL] { konwledgeBase.files }
    
    private var defaultSelection: LocalFileURL? { files.first }
    
    private var preSelection: LocalFileURL? {
        guard let selection = selectedFiles.first else { return defaultSelection }
        return files.element(before: selection)
    }
    
    private var nextSelection: LocalFileURL? {
        guard let selection = selectedFiles.first else { return defaultSelection }
        guard let element = files.element(after: selection) else { return files.first }
        return element
    }
    
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20){
                    ForEach(files) { url in
                        GridCell(url)
                    }
                    .onDelete {
                        konwledgeBase.files.remove(atOffsets: $0)
                    }
                }
                .safeAreaPadding(.top)
            }
            .contentMargins(0, for: .scrollIndicators)
            .onTapGesture(perform: clearSelection)
            .onChange(of: proxy.size.width, initial: true) {
                let count = Int(proxy.size.width / width)
                columns = Array(repeating: GridItem(.fixed(gridCellWidth),
                                                    spacing: columnPadding,
                                                    alignment: .top),
                                count: count)
            }
            .animation(.smooth, value: columns.count)
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { keyPress in
                keyAction(keyPress.key)
            }
        }
        .frame(minWidth: width * 2)
    }
    
    @ViewBuilder
    func GridCell(_ url: URL) -> some View {
        VStack {
            FileThumbnail(url: url, frameWidth: gridCellWidth)
                .padding(Layout.padding)
                .frame(width: gridCellWidth, height: gridCellWidth)
                .background {
                    if selectedFiles.contains(url) {
                        RoundedRectangle().fill(.selection)
                    }
                }
            
            Text(url.lastPathComponent)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
        }
        .frame(width: gridCellWidth)
        .onTapGesture {
#if canImport(AppKit)
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                if selectedFiles.contains(url) {
                    selectedFiles.remove(url)
                } else {
                    selectedFiles.insert(url)
                }
            } else {
                selectedFiles = [url]
            }
#endif
        }
    }
    
}

extension KnowledgeBaseDetailGridView {
    
    func clearSelection() {
        selectedFiles = []
    }
    
    func keyAction(_ key: KeyEquivalent) -> KeyPress.Result {
        var selection: LocalFileURL? = nil
        switch key {
        case .leftArrow: selection = preSelection
        case .rightArrow: selection = nextSelection
        case .upArrow: break
        case .downArrow: break
        default: return .ignored
        }
        if let selection {
            selectedFiles = [selection]
        }
        return .handled
    }
}

#Preview {
    KnowledgeBaseDetailGridView(konwledgeBase: KnowledgeBase(),
                                selectedFiles: .constant([]))
}
