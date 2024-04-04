//
//  KnowledgeBaseDetailGridView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 3/4/2024.
//

import SwiftUI

struct KnowledgeBaseDetailGridView: View {
    
    @Bindable var konwledgeBase: KnowledgeBase
    @Binding var selectedFiles: Set<URL>
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
                .contextMenu {
                    DeleteButton(action: deleteFiles)
                }
            }
            .onChange(of: proxy.size.width, initial: true) {
                columns = Array(repeating: GridItem(.fixed(gridCellWidth), alignment: .top),
                                count: Int(proxy.size.width / gridCellWidth))
            }
            .frame(minWidth: gridCellWidth * 2)
        }
    }
    
    @ViewBuilder
    func GridCell(_ url: URL) -> some View {
        FileItem(url: url, layout: .grid,
                 frameWidth: gridCellWidth - Default.padding * 2)
        .onTapGesture {
            if selectedFiles.contains(url) {
                selectedFiles.remove(url)
            } else {
                selectedFiles.insert(url)
            }
        }
        .padding(Default.padding)
        .background {
            if selectedFiles.contains(url) {
                RoundedRectangle().fill(.selection)
            }
        }
        .frame(width: gridCellWidth)
    }
    
    func deleteFiles() {
        konwledgeBase.files.subtract(selectedFiles)
    }
}


#Preview {
    KnowledgeBaseDetailGridView(konwledgeBase: KnowledgeBase(),
                                selectedFiles: .constant([]))
}
