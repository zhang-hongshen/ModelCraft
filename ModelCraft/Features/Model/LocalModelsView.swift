//
//  LocalModelsView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 4/4/2024.
//

import SwiftUI
import SwiftData

struct LocalModelsView: View {
    
    @State private var selectedModelNames = Set<String>()
    @State private var isFetchingData = false
    @State private var confirmationDialogPresented = false
    
    @Environment(\.modelContext) private var modelContext
    @Environment(\.downaloadedModels) private var models
    
    @Query(filter: ModelTask.predicateByType(.delete))
    private var deleteTasks: [ModelTask] = []
    
    var body: some View {
        List(selection: $selectedModelNames) {
            ForEach(models, id: \.digest) { model in
                HStack {
                    Label(model.name, systemImage: "shippingbox")
                    Spacer()
                    if let task = deleteTasks.first(where: { $0.modelName == model.name }) {
                        Text(task.statusLocalizedDescription)
                    } else {
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(model.size), countStyle: .file))
                    }
                }.tag(model.name)
            }
            .contextMenu {
                DeleteButton(action: { confirmationDialogPresented = true})
            }
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
            DeleteButton(action: { confirmationDialogPresented = true})
        }
    }
}

extension LocalModelsView {
    
    func createDeleteModelTask() {
        let tasks = selectedModelNames.compactMap { modelName in
            ModelTask(modelName: modelName, type: .delete)
        }
        modelContext.persist(tasks)
    }
}

#Preview {
    LocalModelsView()
}
