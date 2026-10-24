//
//  ModelStore.swift
//  ModelCraft
//
//  Created by Hongshen on 23/3/24.
//

import SwiftUI
import SwiftData

struct ModelStore: View {    
    
    @State private var viewMode: ViewMode = .list
    @State private var category: ModelCategory = .text
    
    @State private var models: [ModelStoreModel] = []
    @State private var sizes: [String: Int64] = [:]
    
    @State private var isLoading = false
    @State private var canLoadMore = true
    @State private var searchText = ""
    @State private var page = 0

    @Query(ModelTask.fetchByType(.download))
    private var downloadTasks: [ModelTask] = []
    
    fileprivate static let pageSize = 20
    fileprivate static let columns = [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)]
    
    var body: some View {
        let downloadTasksByModelID = Dictionary(
            uniqueKeysWithValues: downloadTasks.map { ($0.modelID, $0) }
        )

        ScrollView {
            ModelStoreContent(
                models: models,
                sizes: sizes,
                downloadTasksByModelID: downloadTasksByModelID,
                viewMode: viewMode,
                isLoading: isLoading,
                canLoadMore: canLoadMore,
                onLoadMore: loadMoreModels,
                onLoadSize: loadSize)
                .padding()
                .toolbar(content: ToolbarItems)
        }
        .searchable(text: $searchText)
        .refreshable { await reloadModels() }
        .task(id: SearchRequest(keyword: searchText, category: category)) {
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
            Picker("Category", selection: $category) {
                ForEach(ModelCategory.allCases) { category in
                    Text(category.title).tag(category)
                }
            }
            .pickerStyle(.segmented)
            
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
                    .controlSize(.small)
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

private struct SearchRequest: Hashable {
    let keyword: String
    let category: ModelCategory
}

private struct ModelStoreContent: View {
    let models: [ModelStoreModel]
    let sizes: [String: Int64]
    let downloadTasksByModelID: [String: ModelTask]
    let viewMode: ViewMode
    let isLoading: Bool
    let canLoadMore: Bool
    let onLoadMore: () async -> Void
    let onLoadSize: (String) async -> Void

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
                RoundedRectangle()
                    .fill(.quaternary.opacity(0.5))
                    .frame(height: viewMode == .grid ? 150 : 70)
            }
        } else {
            ForEach(models) { model in
                ModelCard(
                    model: model,
                    sizeInBytes: sizes[model.id],
                    viewMode: viewMode,
                    downloadTask: downloadTasksByModelID[model.id])
                .task { await onLoadSize(model.id) }
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
            category: category,
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
    
    /// Loads a size when its card appears; sizes are kept across reloads of this view.
    func loadSize(for modelID: String) async {
        guard sizes[modelID] == nil else { return }
        do {
            sizes[modelID] = try await ModelService.fetchUsedStorage(modelID: modelID)
        } catch {
            guard !Task.isCancelled else { return }
            print("size fetch failed for \(modelID): \(error)")
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

#if DEBUG
#Preview(traits: .preview) {
    ModelStore()
}
#endif
