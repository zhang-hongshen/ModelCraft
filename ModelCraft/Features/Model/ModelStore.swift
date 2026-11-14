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
    @State private var deviceFits: Set<ModelDeviceFit> = []
    
    @State private var models: [ModelStoreModel] = []
    @State private var visibleModels: [ModelStoreModel] = []
    
    @State private var requestID = UUID()
    @State private var isLoadingMore = false
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
                models: visibleModels,
                paginationID: models.last?.id,
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
        .onChange(of: deviceFits) { _, _ in updateVisibleModels() }
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

            Menu("Device Fit") {
                Toggle("All", isOn: Binding(
                    get: { deviceFits.isEmpty },
                    set: { _ in deviceFits.removeAll() }
                ))
                Divider()
                ForEach(ModelDeviceFit.allCases) { fit in
                    Toggle(isOn: Binding(
                        get: { deviceFits.contains(fit) },
                        set: { isSelected in
                            if isSelected {
                                deviceFits.insert(fit)
                            } else {
                                deviceFits.remove(fit)
                            }
                        }
                    )) {
                        Text(fit.title)
                    }
                }
            }
            
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
    let paginationID: String?
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
                RoundedRectangle()
                    .fill(.quaternary.opacity(0.5))
                    .frame(height: viewMode == .grid ? 150 : 70)
            }
        } else {
            ForEach(models) { model in
                ModelCard(
                    model: model,
                    sizeInBytes: model.downloadSizeInBytes,
                    viewMode: viewMode,
                    downloadTask: downloadTasksByModelID[model.id])
            }
            if canLoadMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .task(id: paginationID) { await onLoadMore() }
            }
        }
    }
}

extension ModelStore {

    func updateVisibleModels() {
        visibleModels = models.filter { deviceFits.isEmpty || deviceFits.contains($0.deviceFit) }
    }
    
    private func fetchModels(
        keyword: String, category: ModelCategory, startingAt page: Int
    ) async throws -> (models: [ModelStoreModel], page: Int, hasMore: Bool) {
        var nextPage = page
        while true {
            let result = try await ModelService.searchModel(
                keyword: keyword, category: category,
                page: nextPage, pageSize: ModelStore.pageSize)
            try Task.checkCancellation()
            if !result.models.isEmpty || !result.hasMore {
                return (result.models, nextPage, result.hasMore)
            }
            // Skip pages containing only unsupported or non-conversational models.
            nextPage += 1
        }
    }

    func reloadModels() async {
        let identifier = UUID()
        requestID = identifier
        let request = SearchRequest(keyword: searchText, category: category)
        isLoading = true
        isLoadingMore = false
        defer {
            if requestID == identifier { isLoading = false }
        }
        do {
            let result = try await fetchModels(keyword: request.keyword, category: request.category, startingAt: 0)
            guard requestID == identifier,
                  request == SearchRequest(keyword: searchText, category: category) else { return }
            models = result.models
            page = result.page
            canLoadMore = result.hasMore
            updateVisibleModels()
        } catch {
            // Keep the previous results available when a refresh fails.
        }
    }

    func loadMoreModels() async {
        guard !isLoading, !isLoadingMore, canLoadMore else { return }
        let identifier = requestID
        let request = SearchRequest(keyword: searchText, category: category)
        isLoadingMore = true
        defer {
            if requestID == identifier { isLoadingMore = false }
        }
        do {
            let result = try await fetchModels(keyword: request.keyword, category: request.category, startingAt: page + 1)
            guard requestID == identifier,
                  request == SearchRequest(keyword: searchText, category: category) else { return }
            models.append(contentsOf: result.models)
            page = result.page
            canLoadMore = result.hasMore
            updateVisibleModels()
        } catch {
            // Pagination advances only when the request succeeds.
        }
    }

}

#if DEBUG
#Preview(traits: .preview) {
    ModelStore()
}
#endif
