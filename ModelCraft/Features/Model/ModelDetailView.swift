//
//  ModelDetailView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 3/4/2024.
//

import SwiftUI
import SwiftData
import Combine

import OllamaKit

struct ModelDetailView: View {
    
    @State var modelName: String
    @State private var models: [ModelInfo] = []
    @State private var isLoading = false
    @State private var selectedModelNames = Set<String>()
    @State private var cancellables = Set<AnyCancellable>()
    
    @Query(filter: ModelTask.predicateByType(.download))
    private var downloadTasks: [ModelTask] = []
    @Environment(\.downaloadedModels) private var downloadedModels
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        ContentView()
            .toolbar(content: ToolbarItems)
            .task { fetchModels() }
    }
    
    @ViewBuilder
    func ContentView() -> some View {
        List(selection: $selectedModelNames) {
            ForEach(models, id: \.name) { model in
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
            if downloadedModels.map({ $0.name }).contains(model.name) {
                Text("Downloaded")
            } else if let task = downloadTasks.first(where: { $0.modelName == model.name }) {
                ModelDownloadProgress(task: task)
            } else {
                Button("Download") {
                    createDownloadModelTask(model.name)
                }
            }
        }
    }
}
extension ModelDetailView {
    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        ToolbarItemGroup {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button("Refresh", systemImage: "arrow.triangle.2.circlepath") {
                    fetchModels()
                }
                
            }
        }
    }
}
extension ModelDetailView {
    
    func fetchModels() {
        Task(priority: .userInitiated){
            isLoading = true
            models = try await OllamaClient.shared.modelTags(modelName)
            isLoading = false
        }
    }
    
    func createDownloadModelTask(_ modelName: String) {
        modelContext.persist(ModelTask(modelName: modelName, type: .download))
    }

}

#Preview {
    ModelDetailView(modelName: "gemma")
}
