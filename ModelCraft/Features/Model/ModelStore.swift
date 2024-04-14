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
            .toolbar(content: ToolbarItems)
            .searchable(text: $searchText)
            .task { fetchModels() }
            .navigationDestination(for: String.self) { modelName in
                ModelDetailView(modelName: modelName)
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
                Button("Refresh", systemImage: "arrow.triangle.2.circlepath") {
                    fetchModels()
                }
            }
        }
    }
    
    @ViewBuilder
    func ContentView() -> some View {
        if isLoading {
            List {
                ForEach(0..<5) { _ in
                    Text("This is an Placeholder").redacted(reason: .placeholder)
                }
            }
        } else {
            List(selection: $selectedModelName) {
                ForEach(filteredModels, id: \.name) { model in
                    ListCell(model)
                }
            }
        }
        
    }
    
    @ViewBuilder
    func ListCell(_ model: ModelInfo) -> some View {
        NavigationLink(value: model.name) {
            Label(model.name, systemImage: "shippingbox")
        }
        .buttonStyle(.borderless)
    }
    
}

extension ModelStore {
    
    func fetchModels() {
        Task(priority: .userInitiated) {
            isLoading = true
            do {
                models = try await OllamaClient.shared.libraryModels()
            } catch {
                
            }
            
            isLoading = false
        }
    }

}

#Preview {
    ModelStore()
}
