//
//  ModelDownloadView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 23/3/2024.
//

import SwiftUI
import Combine
import SwiftData


struct ModelDownloadView: View {
    
    @State private var models: [ModelInfo] = []
    @State private var selectedModelNames = Set<String>()
    @State private var searchText = ""
    @State private var cancellables = Set<AnyCancellable>()
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    private var filtedModels: [ModelInfo] {
        if searchText.isEmpty {
            return models
        }
        return models.filter { $0.name.hasPrefix(searchText) }
    }
    
    var body: some View {
        VStack(alignment: .leading) {
            Text("Select models to download")
            
            TextField("Filter", text: $searchText)
            
            List(selection: $selectedModelNames) {
                ForEach(filtedModels, id: \.name) { model in
                    HStack{
                        Text(verbatim: model.name).tag(model.name)
                        Spacer()
                    }
                    .padding(.vertical, 5)
                }
            }
            .listStyle(.inset)
        }
        .safeAreaPadding()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: dismiss.callAsFunction)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Download", action: createDownloadModelTask)
            }
        }
        .task { fetchModels() }
    }
}

extension ModelDownloadView {
    
    func fetchModels() {
        Task {
            models = try await OllamaClient.shared.undownloadedModels()
        }
    }
    
    func createDownloadModelTask() {
        let tasks = selectedModelNames.compactMap { modelName in
            ModelTask(modelName: modelName, type: .download)
        }
        modelContext.persist(tasks)
        dismiss.callAsFunction()
    }
}

#Preview {
    ModelDownloadView()
}
