//
//  KnowledgeBaseDetailView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 31/3/2024.
//

import SwiftUI
import SwiftData

struct KnowledgeBaseDetailView: View {
    
    @Bindable var konwledgeBase: KnowledgeBase
    
    @State private var fileImporterPresented: Bool = false
    @State private var selectedFiles: Set<LocalFileURL> = []
    @State private var selectedViewType: ViewType = .list

    @Environment(\.errorWrapper) private var errorWrapper
    var body: some View {
        ContentView()
            .contextMenu {
                DeleteButton(action: deleteFiles)
            }
            .onDeleteCommand(perform: deleteFiles)
            .toolbar(content: ToolbarItems)
            .fileImporter(isPresented: $fileImporterPresented,
                          allowedContentTypes: [.data, .folder],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    urls.forEach { konwledgeBase.files.insert($0) }
                case .failure(let error):
                    errorWrapper.wrappedValue = ErrorWrapper(error: error,
                                                             guidance: "Please try again!")
                }
            }
            .dropDestination(for: URL.self) { items, location in
                konwledgeBase.files.formUnion(items)
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
                                                selections: $selectedFiles)
        case .grid: KnowledgeBaseDetailGridView(konwledgeBase: konwledgeBase,
                                                selections: $selectedFiles)
        }
            
    }
    
    func deleteFiles() {
        konwledgeBase.files.subtract(selectedFiles)
    }
    
}

