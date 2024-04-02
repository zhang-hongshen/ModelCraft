//
//  ModelView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 22/3/2024.
//

import SwiftUI
import SwiftData
import TipKit

struct ModelsView: View {
    
    @State private var selectedModelNames = Set<String>()
    @State private var isFetchingData = false
    @State private var sheetPresented = false
    
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
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .bottom, content: OpearationButton)
        .sheet(isPresented: $sheetPresented){
            ModelStore()
        }
    }
}

extension ModelsView {
    
    @ViewBuilder
    func OpearationButton() -> some View {
        HStack(alignment: .center) {
            Button(action: createDeleteModelTask, label: { Image(systemName: "minus") })
                .disabled(selectedModelNames.isEmpty)

            Spacer()
        }
        .padding(Default.padding)
        .buttonStyle(.borderless)
    }
}

extension ModelsView {
    
    func createDeleteModelTask() {
        let tasks = selectedModelNames.compactMap { modelName in
            ModelTask(modelName: modelName, type: .delete)
        }
        modelContext.persist(tasks)
    }
}
