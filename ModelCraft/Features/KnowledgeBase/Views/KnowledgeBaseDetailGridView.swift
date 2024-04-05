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
    
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 0){
                    ForEach(konwledgeBase.orderedFiles, id: \.self) { url in
                        GridCell(url)
                    }
                }
                .safeAreaPadding(.top)
            }
            .onTapGesture(perform: clearSelection)
            .onChange(of: proxy.size.width, initial: true) {
                columns = Array(repeating: GridItem(.fixed(gridCellWidth), alignment: .top),
                                count: Int(proxy.size.width / gridCellWidth))
            }
        }
        .frame(minWidth: gridCellWidth * 3)
    }
    
    @ViewBuilder
    func GridCell(_ url: URL) -> some View {
        VStack {
            FileIcon(url: url, layout: .grid,
                     frameWidth: gridCellWidth)
                .frame(width: gridCellWidth)
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
