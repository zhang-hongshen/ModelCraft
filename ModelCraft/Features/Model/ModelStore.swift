//
//  ModelStore.swift
//  ModelCraft
//
//  Created by Hongshen on 23/3/2024.
//

import SwiftUI
import SwiftData

struct ModelStore: View {
    
    @State private var models: [LMModel] = []
    @State private var showSubDownloadingTask = false
    
    @State private var isLoading = false
    @State private var selectedModelName : String? = nil
    @State private var searchText = ""
    @State private var page = 0
    
    private let pageSize = 20
    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]
    
    @Query(filter: ModelTask.predicateUnCompletedDownloadTask,
           sort: \ModelTask.createdAt,
           order: .reverse)
    private var uncompletedDownloadTasks: [ModelTask] = []
    
    private var currentDownloadingTaskProgress: Double {
        let total = uncompletedDownloadTasks.map { $0.totalUnitCount }.reduce(0) { partialResult, currentTotal in
            return partialResult + currentTotal
        }
        if total == 0 {
            return 0
        }
        let current = uncompletedDownloadTasks.map { $0.completedUnitCount }.reduce(0) { partialResult, currentTotal in
            return partialResult + currentTotal
        }
        return Double(current) / Double(total)
    }
    
    var body: some View {
        ScrollView {
            ContentView()
                .padding()
                .toolbar(content: ToolbarItems)
                .searchable(text: $searchText)
                .task {
                    do {
                        models = try await fetchModels()
                    } catch {}
                }
                .onChange(of: searchText) { oldValue, newValue in
                    Task(priority: .background){
                        models = try await fetchModels()
                    }
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
                                Label(task.modelId, systemImage: "shippingbox")
                                Spacer()
                                ModelTaskStatus(task: task)
                            }.tag(task.modelId)
                        }
                    }
                }
            }
            
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button("Refresh", systemImage: "arrow.triangle.2.circlepath") {
                    Task {
                        models = try await fetchModels()
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    func ContentView() -> some View {
        if isLoading {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(0..<10) { _ in
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(height: 220)
                        .redacted(reason: .placeholder)
                }
            }
        } else {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(models) { model in
                    ModelCard(model: model)
                }
                
                EmptyView()
                    .frame(maxWidth: .infinity)
                    .onAppear {
                        Task {
                            page += 1
                            models.append(contentsOf: try await fetchModels())
                        }
                    }
            }
        }
    }
    
}

extension ModelStore {
    
    func fetchModels() async throws -> [LMModel] {
        isLoading = true
        defer { isLoading = false }
        return try await ModelService.shared.fetchModels(keyword: searchText, page: page, pageSize: pageSize)
    }

}

#Preview {
    ModelStore()
        .modelContainer(for: [ModelTask.self], inMemory: true)
}
