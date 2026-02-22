//
//  ModelDetailView.swift
//  ModelCraft
//
//  Created by Hongshen on 3/4/2024.
//

import SwiftUI
import SwiftData

import OllamaKit

struct ModelDetailView: View {
    
    @State var modelName: String
    @State private var models: [ModelInfo] = []
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var selectedModelNames = Set<String>()
    
    @Query(filter: ModelTask.predicateByType(.download))
    private var downloadTasks: [ModelTask] = []
    
    @Environment(\.downaloadedModels) private var downloadedModels
    @Environment(\.modelContext) private var modelContext
    
    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 250), spacing: 16)
    ]
    
    private var filteredModels: [ModelInfo] {
        if searchText.isEmpty {
            return models
        }
        return models.filter { $0.name.hasPrefix(searchText) }
    }
    
    var body: some View {
        ContentView()
            .searchable(text: $searchText)
            .toolbar(content: ToolbarItems)
            .task { fetchModels() }
    }
    
    @ViewBuilder
    func ContentView() -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(filteredModels, id: \.name) { model in
                    TagCard(model)
                }
            }
            .padding()
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.3))
    }
    
    @ViewBuilder
    func ListCell(_ model: ModelInfo) -> some View {
        HStack{
            Label(model.name, systemImage: "shippingbox")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if downloadedModels.map({ $0.name }).contains(model.name) {
                Text("Downloaded")
            } else if let task = downloadTasks.first(where: { $0.modelName == model.name }) {
                ModelTaskStatus(task: task)
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
    
    @ViewBuilder
    func TagCard(_ model: ModelInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "tag.fill")
                    .foregroundStyle(Color.accentColor)
                Text(model.name)
                    .font(.headline)
                    .lineLimit(1)
            }
            
            Divider()
            
            HStack {
                Spacer()
                if downloadedModels.map({ $0.name }).contains(model.name) {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption.bold())
                } else if let task = downloadTasks.first(where: { $0.modelName == model.name }) {
                    ModelTaskStatus(task: task)
                } else {
                    Button {
                        createDownloadModelTask(model.name)
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.1), lineWidth: 1)
        )
    }
}

extension ModelDetailView {
    
    func fetchModels() {
        Task(priority: .userInitiated){
            isLoading = true
            defer { isLoading = false }
            models = try await OllamaService.shared.modelTags(modelName)
        }
    }
    
    func createDownloadModelTask(_ modelName: String) {
        modelContext.persist(ModelTask(modelName: modelName, type: .download))
    }

}


#Preview {
    ModelDetailView(modelName: "deepseek-r1")
}
