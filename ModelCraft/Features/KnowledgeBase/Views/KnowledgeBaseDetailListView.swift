//
//  KnowledgeBaseDetailListView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 3/4/2024.
//

import SwiftUI

struct KnowledgeBaseDetailListView: View {
    
    @Bindable var konwledgeBase: KnowledgeBase
    @Binding var selection: Set<URL>
    
    var body: some View {
        List(selection: $selection) {
            ForEach(konwledgeBase.orderedFiles, id: \.self) { url in
                ListCell(url).tag(url)
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
                                selection: .constant([]))
}
