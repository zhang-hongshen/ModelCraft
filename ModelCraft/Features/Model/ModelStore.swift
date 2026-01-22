//
//  ModelStore.swift
//  ModelCraft
//
//  Created by Hongshen on 23/3/2024.
//

import SwiftUI
import SwiftData
import Combine

import OllamaKit

struct ModelStore: View {
    
    @State private var models: [ModelInfo] = []
    @State private var filtedModels: [ModelInfo] = []
    @State private var showSubDownloadingTask = false
    
    @State private var isLoading = false
    @State private var selectedModelName : String? = nil
    @State private var searchText = ""
    @State private var cancellables = Set<AnyCancellable>()
    
    @Query(filter: ModelTask.predicateUnCompletedDownloadTask,
           sort: \ModelTask.createdAt,
           order: .reverse)
    private var uncompletedDownloadTasks: [ModelTask] = []
    
    private var currentDownloadingTaskProgress: Double {
        let total = uncompletedDownloadTasks.map { $0.total }.reduce(0) { partialResult, currentTotal in
            return partialResult + currentTotal
        }
        if total == 0 {
            return 0
        }
        let current = uncompletedDownloadTasks.map { $0.value }.reduce(0) { partialResult, currentTotal in
            return partialResult + currentTotal
        }
        return current / total
    }
    
    private var orderedModels: [ModelInfo] {
        models.sorted(using: KeyPathComparator(\.name))
    }
    
    private var filteredModels: [ModelInfo] {
        if searchText.isEmpty {
            return orderedModels
        }
        return orderedModels.filter { $0.name.hasPrefix(searchText) }
    }
    
    var body: some View {
        NavigationStack {
            ContentView()
                .toolbar(content: ToolbarItems)
                .searchable(text: $searchText)
                .task { fetchModels() }
                .navigationDestination(for: String.self) { modelName in
                    ModelDetailView(modelName: modelName)
                }
        }
    }
}

extension ModelStore {
    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        ToolbarItemGroup {
            if !uncompletedDownloadTasks.isEmpty {
                Button {
                    showSubDownloadingTask.toggle()
                } label: {
                    ProgressView(value: currentDownloadingTaskProgress, total: 1).controlSize(.small)
                        .progressViewStyle(.circular)
                }
                .popover(isPresented: $showSubDownloadingTask, arrowEdge: .bottom) {
                    List {
                        ForEach(uncompletedDownloadTasks) { task in
                            HStack{
                                Label(task.modelName, systemImage: "shippingbox")
                                Spacer()
                                ModelTaskStatus(task: task)
                            }.tag(task.modelName)
                        }
                    }
                }
            }
            
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button("Refresh", systemImage: "arrow.triangle.2.circlepath") {
                    fetchModels()
                }
            }
        }
    }
    
    @ViewBuilder
    func ContentView() -> some View {
        if models.isEmpty {
            List {
                ForEach(0..<5) { _ in
                    Text("").redacted(reason: .placeholder)
                }
            }
        } else {
            List(selection: $selectedModelName) {
                ForEach(filteredModels, id: \.name) { model in
                    NavigationLink(value: model.name) {
                        Label(model.name, systemImage: "shippingbox")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        
    }
    
}

extension ModelStore {
    
    func fetchModels() {
        Task(priority: .userInitiated) {
            isLoading = true
            defer { isLoading = false }
            models = try await OllamaService.shared.libraryModels()
        }
    }

}

#Preview {
    ModelStore()
        .modelContainer(for: [ModelTask.self], inMemory: true)
}
