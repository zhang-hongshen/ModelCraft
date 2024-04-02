//
//  ModelStore.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 23/3/2024.
//

import SwiftUI
import Combine
import SwiftData

import OllamaKit

struct ModelStore: View {
    
    @State private var models: [ModelInfo] = []
    @State private var filtedModels: [ModelInfo] = []
    @State private var isLoading = false
    @State private var selectedModelNames = Set<String>()
    @State private var searchText = ""
    @State private var cancellables = Set<AnyCancellable>()
    
    @Query(filter: ModelTask.predicateByType(.download))
    private var downloadTasks: [ModelTask] = []
    @Environment(\.downaloadedModels) private var downloadedModels
    @Environment(\.modelContext) private var modelContext
    
    private var filteredModels: [ModelInfo] {
        if searchText.isEmpty {
            return models
        }
        return models.filter { $0.name.hasPrefix(searchText) }
    }
    var body: some View {
        ContentView()
            .toolbar(content: ToolbarItems)
            .searchable(text: $searchText)
            .task { fetchModels() }
    }
}

extension ModelStore {
    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        ToolbarItemGroup {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button("Refresh", systemImage: "arrow.counterclockwise") {
                    fetchModels()
                }
            }
        }
    }
    
    @ViewBuilder
    func ContentView() -> some View {
        List(selection: $selectedModelNames) {
            ForEach(filteredModels, id: \.name) { model in
                ListCell(model).tag(model.name)
            }
        }
        .listStyle(.inset)
    }
    
    @ViewBuilder
    func ListCell(_ model: ModelInfo) -> some View {
        HStack{
            Label(model.name, systemImage: "shippingbox")
            
            Spacer()
            
            if let task = downloadTasks.first(where: { $0.modelName == model.name }) {
                ModelDownloadProgress(task: task)
            } else if downloadedModels.contains(model) {
                Text("Downloaded")
            } else {
                Button("Download") {
                    createDownloadModelTask(model.name)
                }
            }
        }
    }
}

extension ModelStore {
    
    func fetchModels() {
        Task(priority: .userInitiated){
            isLoading = true
            models = try await OllamaClient.shared.libraryModels()
            isLoading = false
        }
    }
    
    func createDownloadModelTask(_ modelName: String) {
        modelContext.persist(ModelTask(modelName: modelName, type: .download))
    }

}

#Preview {
    ModelStore()
}
