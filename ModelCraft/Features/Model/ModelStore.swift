//
//  ModelStore.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 23/3/2024.
//

import SwiftUI
import SwiftData
import Combine

import OllamaKit

struct ModelStore: View {
    
    @State private var models: [ModelInfo] = []
    @State private var filtedModels: [ModelInfo] = []
    @State private var isLoading = false
    @State private var selectedModelName : String? = nil
    @State private var searchText = ""
    @State private var cancellables = Set<AnyCancellable>()
    @State private var columns: [GridItem] = []
    private let gridCellWidth: CGFloat = 100
    
    @Query(filter: ModelTask.predicateByType(.download))
    private var downloadTasks: [ModelTask] = []
    @Environment(\.downaloadedModels) private var downloadedModels
    
    
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
        ContentView()
            .frame(minWidth: gridCellWidth * 2)
            .toolbar(content: ToolbarItems)
            .searchable(text: $searchText)
            .task { fetchModels() }
            .navigationDestination(for: String.self) { modelName in
                ModelDetailView(modelName: modelName)
                    .navigationTitle(modelName)
            }
    }
}

extension ModelStore {
    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        ToolbarItemGroup {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button("Refresh", systemImage: "arrow.counterclockwise") {
                    fetchModels()
                }
            }
        }
    }
    
    @ViewBuilder
    func ContentView() -> some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 0){
                    ForEach(orderedModels, id: \.name) { model in
                        GridCell(model)
                    }
                }
                .padding(.horizontal)
            }
            .onChange(of: proxy.size.width, initial: true) {
                columns = Array(repeating: GridItem(.fixed(gridCellWidth), alignment: .top),
                                count: Int(proxy.size.width / gridCellWidth))
            }
            .frame(minWidth: gridCellWidth * 2)
        }
    }
    
    @ViewBuilder
    func GridCell(_ model: ModelInfo) -> some View {
        NavigationLink(value: model.name) {
            VStack{
                Image(systemName: "shippingbox")
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: gridCellWidth)
                    .scaleEffect(.init(width: 0.6, height: 0.6))
                
                Text(verbatim: model.name)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            }
        }
        .buttonStyle(.borderless)
        .padding(Default.padding)
        .frame(width: gridCellWidth)
    }
}

extension ModelStore {
    
    func fetchModels() {
        Task(priority: .userInitiated){
            isLoading = true
            models = try await OllamaClient.shared.libraryModels()
            isLoading = false
        }
    }

}

#Preview {
    ModelStore()
}
