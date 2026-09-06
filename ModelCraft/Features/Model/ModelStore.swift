//
//  ModelStore.swift
//  ModelCraft
//
//  Created by Hongshen on 23/3/2024.
//

import SwiftUI
import SwiftData

struct ModelStore: View {    
    
    @State private var viewMode: ViewMode = .list
    
    @State private var models: [ModelStoreModel] = []
    
    @State private var isLoading = false
    @State private var canLoadMore = true
    @State private var searchText = ""
    @State private var page = 0

    @Query(ModelTask.fetchByType(.download))
    private var downloadTasks: [ModelTask] = []
    
    fileprivate static let pageSize = 20
    fileprivate static let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]
    
    var body: some View {
        let downloadTasksByModelID = Dictionary(
            uniqueKeysWithValues: downloadTasks.map { ($0.modelID, $0) }
        )

        ScrollView {
            ModelStoreContent(
                models: models,
                downloadTasksByModelID: downloadTasksByModelID,
                viewMode: viewMode,
                isLoading: isLoading,
                canLoadMore: canLoadMore,
                onLoadMore: loadMoreModels)
                .padding()
                .toolbar(content: ToolbarItems)
        }
        .searchable(text: $searchText)
        .refreshable { await reloadModels() }
        .task(id: searchText) {
            if !searchText.isEmpty {
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !Task.isCancelled else { return }
            await reloadModels()
        }
        
    }
}

extension ModelStore {
    
    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Picker("", selection: $viewMode) {
                    Text("as List").tag(ViewMode.list)
                    Text("as Grid").tag(ViewMode.grid)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Image(systemName: viewMode.systemImage)
            }

            if isLoading {
                ProgressView()
            } else {
                Button("Refresh", systemImage: "arrow.triangle.2.circlepath") {
                    Task {
                        await reloadModels()
                    }
                }
            }
        }
    }
    
}

private struct ModelStoreContent: View {
    let models: [ModelStoreModel]
    let downloadTasksByModelID: [String: ModelTask]
    let viewMode: ViewMode
    let isLoading: Bool
    let canLoadMore: Bool
    let onLoadMore: () async -> Void

    var body: some View {
        switch viewMode {
        case .grid:
            LazyVGrid(columns: ModelStore.columns, spacing: 12) {
                rows
            }
        case .list:
            LazyVStack(spacing: 12) {
                rows
            }
        }
    }

    @ViewBuilder
    private var rows: some View {
        if isLoading {
            ForEach(0..<ModelStore.pageSize, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(height: 100)
                    .redacted(reason: .placeholder)
            }
        } else {
            ForEach(models) { model in
                ModelCard(
                    model: model,
                    viewMode: viewMode,
                    downloadTask: downloadTasksByModelID[model.id])
            }
            if canLoadMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .task { await onLoadMore() }
            }
        }
    }
}

extension ModelStore {
    
    func fetchModels() async throws -> [ModelStoreModel] {
        let models = try await ModelService.searchModel(
            keyword: searchText,
            page: page,
            pageSize: ModelStore.pageSize)
        if models.count < ModelStore.pageSize {
            canLoadMore = false
        }
        return models
    }
    
    func reloadModels() async {
        page = 0
        isLoading = true
        canLoadMore = true
        defer { isLoading = false }
        do {
            models = try await fetchModels()
        } catch {
            
        }
    }
    
    func loadMoreModels() async {
        page += 1
        do {
            models.append(contentsOf: try await fetchModels())
        } catch {
            page -= 1
        }
        
    }

}

#Preview(traits: .preview) {
    ModelStore()
}
