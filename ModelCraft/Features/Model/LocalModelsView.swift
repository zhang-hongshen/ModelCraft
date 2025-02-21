//
//  LocalModelsView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 4/4/2024.
//

import SwiftUI
import SwiftData

import OllamaKit

struct LocalModelsView: View {
    
    @State private var selectedModelNames: Set<String> = []
    @State private var selectedTasks: Set<ModelTask> = []
    @State private var isFetchingData = false
    @State private var confirmationDialogPresented = false
    
    @Environment(\.modelContext) private var modelContext
    @Environment(\.downaloadedModels) private var models
    
    @Query(filter: ModelTask.predicateByType(.delete),
           sort: \ModelTask.createdAt,
           order: .reverse)
    private var deleteTasks: [ModelTask] = []
    
    @Query(filter: ModelTask.predicateUnCompletedDownloadTask(),
           sort: \ModelTask.createdAt,
           order: .reverse)
    private var uncompletedDownloadTasks: [ModelTask] = []
    
    var body: some View {
        List(selection: $selectedModelNames) {
            ForEach(models, id: \.name) { model in
                DownloadedModelListCell(model).tag(model.name)
            }
            ForEach(uncompletedDownloadTasks) { task in
                HStack{
                    Label(task.modelName, systemImage: "shippingbox")
                    Spacer()
                    ModelTaskStatus(task: task)
                }.tag(task.modelName)
            }.foregroundStyle(.secondary)
        }
        .contextMenu {
            DeleteButton(action: { confirmationDialogPresented = true })
        }
        .listStyle(.inset)
        .toolbar(content: ToolbarItems)
        .confirmationDialog("Are you sure to delete these models",
                            isPresented: $confirmationDialogPresented) {
            DeleteButton(action: createDeleteModelTask)
        }
    }
    
}

extension LocalModelsView {
    
    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        ToolbarItem {
            DeleteButton(action: { confirmationDialogPresented = true })
        }
    }
    
    @ViewBuilder
    func DownloadedModelListCell(_ model: ModelInfo) -> some View {
        HStack {
            Label(model.name, systemImage: "shippingbox")
            Spacer()
            if let task = deleteTasks.first(where: { $0.modelName == model.name }) {
                Text(task.statusLocalizedDescription)
            } else {
                Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(model.size), countStyle: .file))
            }
        }
    }
    
}

extension LocalModelsView {
    
    func createDeleteModelTask() {
        let tasks = selectedModelNames.compactMap { modelName in
            ModelTask(modelName: modelName, type: .delete)
        }
        modelContext.persist(tasks)
        modelContext.delete(selectedTasks)
    }
}

#Preview {
    LocalModelsView()
}
