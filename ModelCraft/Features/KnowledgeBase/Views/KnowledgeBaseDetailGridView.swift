//
//  KnowledgeBaseDetailGridView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 3/4/2024.
//

import SwiftUI

struct KnowledgeBaseDetailGridView: View {
    
    @Bindable var konwledgeBase: KnowledgeBase
    @Binding var selection: Set<URL>
    @State private var columns: [GridItem] = []
    private let gridCellWidth: CGFloat = 80
    private let columnPadding: CGFloat = 20
    // gridCellWidth + columnPadding
    private let width: CGFloat = 100
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20){
                    ForEach(konwledgeBase.orderedFiles) { url in
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
                    if selection.contains(url) {
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
                if selection.contains(url) {
                    selection.remove(url)
                } else {
                    selection.insert(url)
                }
            } else {
                selection = [url]
            }
        }
    }

    func clearSelection() {
        selection = []
    }
}


#Preview {
    KnowledgeBaseDetailGridView(konwledgeBase: KnowledgeBase(),
                                selection: .constant([]))
}
