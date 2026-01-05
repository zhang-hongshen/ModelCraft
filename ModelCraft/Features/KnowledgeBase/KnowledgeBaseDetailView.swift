//
//  KnowledgeBaseDetailView.swift
//  ModelCraft
//
//  Created by Hongshen on 31/3/2024.
//

import SwiftUI
import SwiftData

struct KnowledgeBaseDetailView: View {
    
    @Bindable var konwledgeBase: KnowledgeBase
    
    @State private var fileImporterPresented: Bool = false
    @State private var selectedFiles: Set<LocalFileURL> = []
    @State private var selectedViewType: ViewType = .list

    @Environment(GlobalStore.self)private var globalStore
    
    var body: some View {
        ContentView()
            .contextMenu {
                DeleteButton(style: .textOnly) {
                    konwledgeBase.removeFiles(selectedFiles)
                }
            }
            #if os(macOS)
            .onDeleteCommand {
                konwledgeBase.removeFiles(selectedFiles)
            }
            #endif
            .toolbar(content: ToolbarItems)
            .fileImporter(isPresented: $fileImporterPresented,
                          allowedContentTypes: [.data, .folder],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    urls.forEach { konwledgeBase.files.append($0) }
                case .failure(let error):
                    globalStore.errorWrapper = ErrorWrapper(error: error,
                                                            recoverySuggestion: "Please try again later!")
                }
            }
            .dropDestination(for: URL.self) { items, location in
                konwledgeBase.files.append(contentsOf: items)
                return true
            }
    }
}

extension KnowledgeBaseDetailView {
    
    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        ToolbarItemGroup {
            Picker("View", selection: $selectedViewType) {
                ForEach(ViewType.allCases) {
                    Label($0.localizedDescription, systemImage: $0.systemImage)
                }
            }.pickerStyle(.segmented)
            Button("Add Files", systemImage: "doc.badge.plus") {
                fileImporterPresented = true
            }
        }
    }
    
    @ViewBuilder
    func ContentView() -> some View {
        switch selectedViewType {
        case .list: KnowledgeBaseDetailListView(konwledgeBase: konwledgeBase,
                                                selectedFiles: $selectedFiles)
        case .grid: KnowledgeBaseDetailGridView(konwledgeBase: konwledgeBase,
                                                selectedFiles: $selectedFiles)
        }
            
    }
}

#Preview {
    KnowledgeBaseDetailView(konwledgeBase: KnowledgeBase())
        .environment(GlobalStore())
}
