//
//  ModelView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 22/3/2024.
//

import SwiftUI
import SwiftData

struct ModelsView: View {
    
    @State private var models: [ModelInfo] = []
    @State private var selectedModelNames = Set<String>()
    @State private var isFetchingData = false
    @State private var sheetPresented = false
    
    @Query private var modelTasks: [ModelTask] = []
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        VStack(alignment: .leading) {
            List(selection: $selectedModelNames) {
                ForEach(models, id: \.name) { model in
                    HStack {
                        Text(verbatim: model.name)
                        Spacer()
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(model.size), countStyle: .file))
                    }.tag(model.name)
                    .padding(.vertical, 5)
                }
                
                ForEach(modelTasks) { task in
                    HStack {
                        Text(verbatim: task.modelName)
                        Spacer()
                        FileDownloadProgress(task)
                    }.tag(task.modelName)
                    .padding(.vertical, 5)
                }
            }
            .listStyle(.inset)
            .safeAreaInset(edge: .bottom, content: OpearationButton)
            .padding()
            
        }
        .sheet(isPresented: $sheetPresented){
            ModelDownloadView()
                .presentationDetents([.medium])
        }
        .task { fetchData() }
    }
}

extension ModelsView {
    
    @ViewBuilder
    func OpearationButton() -> some View {
        HStack(alignment: .center) {
            Button(action: { sheetPresented = true }, label: { Image(systemName: "plus") })
            Button(action: createDeleteModelTask, label: { Image(systemName: "minus") })
                .disabled(selectedModelNames.isEmpty)

            Spacer()
            
            if isFetchingData {
                ProgressView().controlSize(.small)
            } else {
                Button(action: fetchData, label: { Image(systemName: "arrow.clockwise") })
                    .disabled(isFetchingData)
            }
        }
        .padding(5)
        .buttonStyle(.borderless)
    }
    
    @ViewBuilder
    func FileDownloadProgress(_ task: ModelTask) -> some View {
        HStack(alignment: .center) {
            if task.value > 0 &&  task.total > 0 {
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(task.value), countStyle: .file))/\(ByteCountFormatter.string(fromByteCount: Int64(task.total), countStyle: .file))")
            }
            ProgressView(value: task.value,
                         total: task.total)
                .controlSize(.small)
                .progressViewStyle(.circular)
        }
    }
}

extension ModelsView {
    
    func fetchData() {
        isFetchingData = true
        Task {
            do {
                models = try await OllamaClient.shared.models().models
            } catch {
                debugPrint(error.localizedDescription)
            }
            isFetchingData = false
        }
    }
    
    func createDeleteModelTask() {
        let tasks = selectedModelNames.compactMap { modelName in
            ModelTask(modelName: modelName, type: .delete)
        }
        modelContext.persist(tasks)
    }
}
