//
//  KnowledgeBaseDetailListView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 3/4/2024.
//

import SwiftUI

struct KnowledgeBaseDetailListView: View {
    
    @Bindable var konwledgeBase: KnowledgeBase
    @Binding var selectedFiles: Set<URL>
    
    var body: some View {
        List(selection: $selectedFiles) {
            ForEach(konwledgeBase.orderedFiles, id: \.self) { url in
                FileItem(url: url).tag(url)
            }
        }
        .listStyle(.inset)
        .contextMenu {
            DeleteButton()
        }
    }
    
    @ViewBuilder
    func DeleteButton() -> some View {
        Button("Delete", systemImage: "trash", action: deleteFiles)
    }
    
    func deleteFiles() {
        konwledgeBase.files.subtract(selectedFiles)
    }
}

#Preview {
    KnowledgeBaseDetailListView(konwledgeBase: KnowledgeBase(),
                                selectedFiles: .constant([]))
}
