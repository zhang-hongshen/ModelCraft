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
    @State private var selectedModelName : String? = nil
    @State private var searchText = ""
    @State private var page = 0
    @State private var searchTask: Task<Void, Never>? = nil
    
    @Environment(\.horizontalSizeClass) private var sizeClass
    
    private static let pageSize = 20
    private static let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]
    
    var body: some View {
        ScrollView {
            ContentView()
                .padding()
                .toolbar(content: ToolbarItems)
        }
        .searchable(text: $searchText)
        .refreshable { await reloadModels() }
        .task { await reloadModels() }
        .onChange(of: searchText) { oldValue, newValue in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if !Task.isCancelled {
                    await reloadModels()
                }
            }
        }
        
    }
}

extension ModelStore {
    
    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        ToolbarItemGroup {
            
            if sizeClass == .regular {
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
            }
            
            if isLoading {
                ProgressView()
                    .progressViewStyle(.scaled)
            } else {
                Button("Refresh", systemImage: "arrow.triangle.2.circlepath") {
                    Task {
                        await reloadModels()
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    func LoadMoreView() -> some View {
        ProgressView()
            .progressViewStyle(.scaled)
            .frame(maxWidth: .infinity)
            .onAppear {
                Task { await loadMoreModels() }
            }
    }
    
    @ViewBuilder
    func ContentView() -> some View {
        switch viewMode {
        case .grid:
            if isLoading {
                GridLoadingView()
            } else {
                GridView()
            }
            
        case .list:
            if isLoading {
                ListLoadingView()
            } else {
                ListView()
            }
            
        }
        
    }
    
    @ViewBuilder
    func GridLoadingView() -> some View {
        LazyVGrid(columns: ModelStore.columns, spacing: 12) {
            ForEach(0..<ModelStore.pageSize, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(height: 100)
                    .redacted(reason: .placeholder)
            }
        }
    }
    
    @ViewBuilder
    func GridView() -> some View {
        LazyVGrid(columns: ModelStore.columns, spacing: 12) {
            ForEach(models) { model in
                ModelCard(model: model, viewMode: viewMode)
            }
            LoadMoreView()
        }
    }
    
    @ViewBuilder
    func ListLoadingView() -> some View {
        LazyVStack(spacing: 12) {
            ForEach(0..<ModelStore.pageSize, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(height: 100)
                    .redacted(reason: .placeholder)
            }
        }
    }
    
    @ViewBuilder
    func ListView() -> some View {
        LazyVStack(alignment: .center,spacing: 12) {
            ForEach(models) { model in
                ModelCard(model: model, viewMode: viewMode)
            }
            LoadMoreView()
        }
    }
    
}

extension ModelStore {
    
    func fetchModels() async throws -> [ModelStoreModel] {
        return try await ModelService.shared.searchModel(keyword: searchText, page: page, pageSize: ModelStore.pageSize)
    }
    
    func reloadModels() async {
        page = 0
        isLoading = true
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

#Preview {
    ModelStore()
        .modelContainer(for: [ModelTask.self], inMemory: true)
        .environment(GlobalStore())
}
