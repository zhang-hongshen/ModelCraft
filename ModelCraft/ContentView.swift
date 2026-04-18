//
//  ContentView.swift
//  ModelCraft
//
//  Created by Hongshen on 22/3/2024.
//

import SwiftUI
import SwiftData
import OrderedCollections

struct ContentView: View {
    
    @State private var selectedProject: Project? = nil
    
    @Query(sort: \Chat.createdAt, order: .reverse) private var chats: [Chat]
    @Query(sort: \Project.createdAt, order: .reverse) private var projects: [Project]
    
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    
    @Environment(GlobalStore.self) private var globalStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    var body: some View {
        if horizontalSizeClass == .regular {
            RegularLayout()
        } else {
            CompactLayout()
        }
        
    }
}

extension ContentView {
    
    @ViewBuilder
    func RegularLayout() -> some View {
        NavigationSplitView {
            Sidebar()
        } detail: {
            Detail()
        }
        .sheet(item: $selectedProject) { project in
            ProjectEdition(project: project)
        }
    }
    
    @ViewBuilder
    func Sidebar() -> some View {
        @Bindable var store = globalStore
        
        List(selection: $store.currentTab) {
            ChatSection()
            ProjectSection()
            ModelSection()
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 160, ideal: 170, max: 180)
    }
    
    @ViewBuilder
    func ChatSection() -> some View {
        Section {
            ForEach(chats) { chat in
                Text(chat.title ?? "New Chat").tag(AppNavigationTab.chat(chat))
                    .contextMenu{
                        DeleteButton(style: .textOnly) {
                            modelContext.delete(chat)
                        }
                        Menu("Move to project") {
                            ForEach(projects) { project in
                                Button(project.title) {
                                    chat.project = project
                                }
                            }
                        }
                    }
            }
            .onDelete(perform: deleteChats)
        } header: {
            HStack {
                Text("Chat")
                Button(action: addChat, label: {
                    Image(systemName: "plus")
                }).buttonStyle(.borderless)
                    .disabled(chats.last?.messages.isEmpty ?? false)
            }
        }
    }
    
    @ViewBuilder
    func ProjectSection() -> some View {
        Section {
            ForEach(projects) { project in
                Label(project.title, systemImage: "book")
                    .tag(AppNavigationTab.project(project))
                    .contextMenu{
                        Button("Edit") {
                            selectedProject = project
                        }
                        DeleteButton(style: .textOnly) {
                            modelContext.delete(project)
                        }
                    }
            }
        } header: {
            HStack {
                Text("Project")
                Button(action: {
                    selectedProject = Project()
                }, label: {
                    Image(systemName: "plus")
                }).buttonStyle(.borderless)
            }
        }
    }
    
    @ViewBuilder
    func ModelSection() -> some View {
        Section {
            Label("Model Store", systemImage: "storefront").tag(AppNavigationTab.modelStore)
            Label("Downloaded Models", systemImage: "shippingbox").tag(AppNavigationTab.downloadedModels)
        } header: {
            Text("Model")
        }
    }
    
    @ViewBuilder
    func Detail() -> some View {
        switch globalStore.currentTab {
        case .chat(let chat):
            ChatView(chat: chat).navigationTitle(chat.title ?? "New Chat")
        case .modelStore:
            ModelStore().navigationTitle("Model Store")
        case .project(let project):
            ProjectView(project: project)
                .navigationTitle(project.title)
        case .downloadedModels:
            DownloadedModelsView().navigationTitle("Downloaded Models")
        case .none:
            ChatView(chat: nil)
        }
    }
}

extension ContentView {
    
    @ViewBuilder
    func CompactLayout() -> some View {
                
        NavigationStack {
            switch globalStore.currentTab {
            case .chat(let chat):
                ChatView(chat: chat)
            default:
                ChatView(chat: nil)
            }
        }
    }
}


extension ContentView {
    private func addChat() {
        withAnimation {
            globalStore.currentTab = .none
        }
    }

    private func deleteChats(chats: Set<Chat>) {
        withAnimation {
            for chat in chats {
                modelContext.delete(chat)
            }
            try? modelContext.save()
        }
    }
    
    private func deleteChats(offsets: IndexSet) {
        withAnimation {
            offsets.map { chats[$0] }.forEach(modelContext.delete)
            try? modelContext.save()
        }
    }
    
    
}

#Preview {
    ContentView()
        .modelContainer(for: [Chat.self, ModelTask.self],
                        inMemory: true)
        .environment(GlobalStore())
}
