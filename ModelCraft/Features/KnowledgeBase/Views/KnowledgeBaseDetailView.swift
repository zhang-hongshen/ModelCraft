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
    @State private var selectedFiles: Set<URL> = []
    @State private var selectedViewType: ViewType = .list

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
                    print(error.localizedDescription)
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
        ToolbarItemGroup(placement: .principal) {
            Picker("View", selection: $selectedViewType) {
                ForEach(ViewType.allCases) {
                    Label($0.localizedDescription, systemImage: $0.systemImage)
                }
            }.pickerStyle(.segmented)
            
        }
        ToolbarItemGroup {
            Button("Add Files", systemImage: "doc.badge.plus") {
                fileImporterPresented = true
            }
        }
    }
    
    @ViewBuilder
    func ContentView() -> some View {
        switch selectedViewType {
        case .list: KnowledgeBaseDetailListView(konwledgeBase: konwledgeBase,
                                                selection: $selectedFiles)
        case .grid: KnowledgeBaseDetailGridView(konwledgeBase: konwledgeBase,
                                                selection: $selectedFiles)
        }
            
    }
    
    func deleteFiles() {
        konwledgeBase.files.subtract(selectedFiles)
    }
    
}

