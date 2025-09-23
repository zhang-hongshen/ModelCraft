//
//  KnowledgeBaseDetailListView.swift
//  ModelCraft
//
//  Created by Hongshen on 3/4/2024.
//

import SwiftUI

struct KnowledgeBaseDetailListView: View {
    
    @Bindable var konwledgeBase: KnowledgeBase
    @Binding var selectedFiles: Set<LocalFileURL>
    
    var body: some View {
        List(selection: $selectedFiles) {
            ForEach(konwledgeBase.files) { url in
                ListCell(url).tag(url)
            }
            .onDelete {
                konwledgeBase.files.remove(atOffsets: $0)
            }
        }
        .listStyle(.inset)
    }
    
    @ViewBuilder
    func ListCell(_ url: URL) -> some View {
        Label {
            Text(url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            FileThumbnail(url: url)
        }
    }
}

#Preview {
    KnowledgeBaseDetailListView(konwledgeBase: KnowledgeBase(),
                                selectedFiles: .constant([]))
}
