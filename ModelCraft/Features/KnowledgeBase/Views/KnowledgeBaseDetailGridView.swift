//
//  KnowledgeBaseDetailGridView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 3/4/2024.
//

import SwiftUI

struct KnowledgeBaseDetailGridView: View {
    
    @Bindable var konwledgeBase: KnowledgeBase
    @Binding var selections: Set<LocalFileURL>
    
    @State private var columns: [GridItem] = []
    
    private let gridCellWidth: CGFloat = 80
    private let columnPadding: CGFloat = 20
    // gridCellWidth + columnPadding
    private let width: CGFloat = 100
    
    private var files: [LocalFileURL] { konwledgeBase.orderedFiles }
    
    private var defaultSelection: LocalFileURL? { files.first }
    
    private var preSelection: LocalFileURL? {
        guard let selection = selections.first else { return defaultSelection }
        return files.element(before: selection)
    }
    
    private var nextSelection: LocalFileURL? {
        guard let selection = selections.first else { return defaultSelection }
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
                .padding(Default.padding)
                .frame(width: gridCellWidth, height: gridCellWidth)
                .background {
                    if selections.contains(url) {
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
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                if selections.contains(url) {
                    selections.remove(url)
                } else {
                    selections.insert(url)
                }
            } else {
                selections = [url]
            }
        }
    }
    
}

extension KnowledgeBaseDetailGridView {
    
    func clearSelection() {
        selections = []
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
            selections = [selection]
        }
        return .handled
    }
}

#Preview {
    KnowledgeBaseDetailGridView(konwledgeBase: KnowledgeBase(),
                                selections: .constant([]))
}
