//
//  ModelView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 22/3/2024.
//

import SwiftUI
import SwiftData
import TipKit

struct OpenStoreTip: Tip {
    var title: Text {
        Text("Open ModelStore")
    }
    
    var message: Text? {
        Text("Explore and download models to chat.")
    }
}

struct ModelsView: View {
    
    @State private var selectedModelNames = Set<String>()
    @State private var isFetchingData = false
    @State private var sheetPresented = false
    
    @Environment(\.modelContext) private var modelContext
    @Environment(\.downaloadedModels) private var models
    
    @Query(filter: ModelTask.predicateByType(.download))
    private var downloadTasks: [ModelTask] = []
    @Query(filter: ModelTask.predicateByType(.delete))
    private var deleteTasks: [ModelTask] = []
    
    private let openStoreTip = OpenStoreTip()
    
    var body: some View {
        VStack(alignment: .leading) {
            List(selection: $selectedModelNames) {
                ForEach(models, id: \.digest) { model in
                    HStack {
                        Label(model.name, systemImage: "shippingbox")
                        Spacer()
                        
                        Group {
                            if let task = deleteTasks.first(where: { $0.modelName == model.name }) {
                                Text(task.statusLocalizedDescription)
                            } else {
                                Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(model.size), countStyle: .file))
                            }
                        }.foregroundStyle(.secondary)
                        
                    }.tag(model.name)
                    .padding(.vertical, Default.padding)
                }
                
                ForEach(downloadTasks) { task in
                    HStack {
                        Label(task.modelName, systemImage: "shippingbox")
                        Spacer()
                        ModelDownloadProgress(task: task)
                    }.tag(task.modelName)
                    .padding(.vertical, Default.padding)
                }
            }
            .listStyle(.inset)
            .safeAreaInset(edge: .bottom, content: OpearationButton)
        }
        .sheet(isPresented: $sheetPresented){
            ModelStore()
                .presentationDetents([.medium])
        }
    }
}

extension ModelsView {
    
    @ViewBuilder
    func OpearationButton() -> some View {
        HStack(alignment: .center) {
            Button(action: {
                sheetPresented = true
                openStoreTip.invalidate(reason: .actionPerformed)
            }, label: { Image(systemName: "plus") })
            .popoverTip(openStoreTip, arrowEdge: .top)
            
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
