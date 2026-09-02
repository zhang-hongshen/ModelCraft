//
//  DownloadedModelsView.swift
//  ModelCraft
//
//  Created by Hongshen on 4/4/2024.
//

import SwiftUI
import SwiftData

struct DownloadedModelsView: View {

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter
    }()
    
    @State private var selectedModelIds: Set<String> = []
    @State private var confirmationDialogPresented = false
    
    @Environment(\.modelContext) private var modelContext
    @Environment(LocalModelStore.self) private var localModelStore
    
    @Query(ModelTask.fetchByType(.delete))
    private var deleteTasks: [ModelTask] = []
    
    @Query(ModelTask.fetchUnCompletedDownloadTask)
    private var uncompletedDownloadTasks: [ModelTask] = []
    
    var body: some View {
        List(selection: $selectedModelIds) {
            
            ForEach(localModelStore.models) { model in
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
    
    func DownloadedModelListCell(_ model: LocalModel) -> some View {
        HStack {
            Label(model.displayName, systemImage: "shippingbox")
            
            Spacer()
            
            Text(DownloadedModelsView.byteCountFormatter.string(fromByteCount: model.size))
            
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

#Preview(traits: .preview) {
    DownloadedModelsView()
}
