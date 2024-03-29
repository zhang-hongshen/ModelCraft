//
//  ModelStore.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 23/3/2024.
//

import SwiftUI
import Combine
import SwiftData

import OllamaKit

struct ModelStore: View {
    
    @State private var models: [ModelInfo] = []
    @State private var isLoading = false
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
        VStack(alignment: .center) {
            Text("Select models to download")
            
            TextField("Filter", text: $searchText)
            
            if isLoading {
                ProgressView()
            } else {
                List(selection: $selectedModelNames) {
                    ForEach(filtedModels, id: \.name) { model in
                        HStack{
                            Label(model.name, systemImage: "shippingbox")
                            Spacer()
                        }.tag(model.name)
                        .padding(.vertical, Default.padding)
                    }
                }
                .listStyle(.inset)
                .frame(minWidth: 200, minHeight: 100)
            }
            
        }
        .safeAreaPadding()
        .background(.ultraThinMaterial)
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

extension ModelStore {
    
    func fetchModels() {
        Task.detached(priority: .userInitiated){
            isLoading = true
            models = try await OllamaClient.shared.undownloadedModels()
            isLoading = false
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
    ModelStore()
}
