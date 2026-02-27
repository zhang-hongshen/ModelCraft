//
//  DownloadedModelsView.swift
//  ModelCraft
//
//  Created by Hongshen on 4/4/2024.
//

import SwiftUI
import SwiftData

struct DownloadedModelsView: View {
    
    @State private var selectedModelIds: Set<String> = []
    @State private var selectedTasks: Set<ModelTask> = []
    @State private var isFetchingData = false
    @State private var confirmationDialogPresented = false
    
    @Environment(\.modelContext) private var modelContext
    @Environment(\.downaloadedModels) private var models
    
    @Query(filter: ModelTask.predicateByType(.delete),
           sort: \ModelTask.createdAt,
           order: .reverse)
    private var deleteTasks: [ModelTask] = []
    
    @Query(filter: ModelTask.predicateUnCompletedDownloadTask,
           sort: \ModelTask.createdAt,
           order: .reverse)
    private var uncompletedDownloadTasks: [ModelTask] = []
    
    var body: some View {
        List(selection: $selectedModelIds) {
            ForEach(models) { model in
                DownloadedModelListCell(model).tag(model.name)
            }
            ForEach(uncompletedDownloadTasks) { task in
                HStack{
                    Label(task.modelId, systemImage: "shippingbox")
                    Spacer()
                    ModelTaskStatus(task: task)
                }.tag(task.modelId)
            }.foregroundStyle(.secondary)
        }
        .contextMenu {
            DeleteButton(style: .textOnly,
                         action: { confirmationDialogPresented = true })
        }
        .listStyle(.inset)
        .toolbar(content: ToolbarItems)
        .confirmationDialog("Are you sure to delete these models",
                            isPresented: $confirmationDialogPresented) {
            DeleteButton(style: .textOnly,
                         action: createDeleteModelTask)
        }
    }
    
}

extension DownloadedModelsView {
    
    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        ToolbarItem {
            DeleteButton(style: .iconOnly) {
                confirmationDialogPresented = true
            }
        }
    }
    
    @ViewBuilder
    func DownloadedModelListCell(_ model: LMModel) -> some View {
        HStack {
            Label(model.name, systemImage: "shippingbox")
            
            Spacer()
            if let task = deleteTasks.first(where: { $0.modelId == model.id }) {
                Text(task.statusLocalizedDescription)
            }
        }
    }
    
}

extension DownloadedModelsView {
    
    func createDeleteModelTask() {
        let tasks = selectedModelIds.compactMap { modelId in
            ModelTask(modelId: modelId, type: .delete)
        }
        modelContext.persist(tasks)
        modelContext.delete(selectedTasks)
    }
}

#Preview {
    DownloadedModelsView()
        .modelContainer(for: [ModelTask.self], inMemory: true)
}
