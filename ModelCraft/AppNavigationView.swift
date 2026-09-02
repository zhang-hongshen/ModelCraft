//
//  AppNavigationView.swift
//  ModelCraft
//
//  Created by Hongshen on 16/5/26.
//

import SwiftUI
import SwiftData

struct AppNavigationView: View {
    
    @State private var selectedProject: Project? = nil
    @State private var isProjectsExpanded: Bool = true
    @State private var isRecentsExpanded: Bool = true
    
    @Query(Chat.fetch()) private var chats: [Chat]
    @Query(Project.fetch()) private var projects: [Project]
    
    @Environment(\.modelContext) private var modelContext
    @Environment(GlobalStore.self) private var globalStore
    
    var body: some View {
        @Bindable var store = globalStore
        List(selection: $store.currentTab) {
            Button {
                addChat()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            
            Label("Model Store", systemImage: "storefront").tag(AppNavigationTab.modelStore)
            Label("Downloaded Models", systemImage: "shippingbox").tag(AppNavigationTab.downloadedModels)
            ProjectSection()
            ChatSection()
        }
        .listStyle(.sidebar)
        .sheet(item: $selectedProject) { project in
            ProjectEdition(project: project)
                .presentationDetents([.medium, .large])
        }
        
    }
    
    @ViewBuilder
    func ChatSection() -> some View {
        Section("Recents", isExpanded: $isRecentsExpanded) {
            ForEach(chats) { chat in
                Text(chat.title ?? String(localized: "New Chat")).tag(AppNavigationTab.chat(chat))
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
        }
    }
    
    @ViewBuilder
    func ProjectSection() -> some View {
        Section("Projects", isExpanded: $isProjectsExpanded) {
            
            Button {
                selectedProject = Project()
            } label: {
                Label("New Project", systemImage: "plus")
            }.buttonStyle(.borderless)

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
        }
    }
    
    
}

extension AppNavigationView {
    
    private func addChat() {
        withAnimation {
            globalStore.currentTab = nil
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

#Preview(traits: .preview) {
    AppNavigationView()
}
