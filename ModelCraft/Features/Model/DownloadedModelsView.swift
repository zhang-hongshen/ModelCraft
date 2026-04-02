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
    @State private var confirmationDialogPresented = false
    
    @Environment(\.modelContext) private var modelContext
    
    @Query(sort: \LocalModel.createdAt, order: .reverse) private var models: [LocalModel]
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
                DownloadedModelListCell(model).tag(model.id)
            }
            
            ForEach(uncompletedDownloadTasks) { task in
                ModelTaskView(task: task).tag(task.modelID)
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
    func DownloadedModelListCell(_ model: LocalModel) -> some View {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        
        return
        HStack {
            Label(model.displayName, systemImage: "shippingbox")
            
            Spacer()
            
            Text(formatter.string(fromByteCount: model.size))
            
            if let task = deleteTasks.first(where: { $0.modelID == model.id }) {
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
    }
}

#Preview {
    DownloadedModelsView()
        .modelContainer(for: [ModelTask.self], inMemory: true)
}
