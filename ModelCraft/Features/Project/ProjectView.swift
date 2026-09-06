//
//  ProjectView.swift
//  ModelCraft
//
//  Created by Hongshen on 31/3/2024.
//

import SwiftUI
import SwiftData

struct ProjectView: View {
    
    enum ProjectViewTab: Hashable {
        case chat, file
    }
    
    @Bindable var project: Project
    
    @State private var folderImporterPresented = false
    @State private var resourceImporterPresented = false
    @State private var selectedTab: ProjectViewTab = .chat
    @State private var projectEditionPresented: Bool = false
    
    @Environment(GlobalStore.self)private var globalStore
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        ContentView()
            .padding(.top)
            .toolbar(content: ToolbarItems)
            .fileImporter(isPresented: $folderImporterPresented,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result {
                    project.workingDirectory = urls.first?.standardizedFileURL
                }
            }
            .fileImporter(isPresented: $resourceImporterPresented,
                          allowedContentTypes: [.data],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    project.addResources(urls)
                case .failure(let error):
                    print(error.localizedDescription)
                }
            }
            .sheet(isPresented: $projectEditionPresented){
              ProjectEdition(project: project)
            }
            .dropDestination(for: URL.self) { items, _ in
                addDroppedItems(items)
                return true
            }
    }
}

extension ProjectView {
    
    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        
        ToolbarItemGroup(placement: .primaryAction){
            Menu("Add", systemImage: "plus") {
                Button("Choose Folder", systemImage: "folder") {
                    folderImporterPresented = true
                }
                Button("Add Files", systemImage: "doc.badge.plus") {
                    resourceImporterPresented = true
                }
            }
            Menu {
                
                Button("Edit") {
                    projectEditionPresented = true
                }
                DeleteButton(style: .iconAndText) {
                    project.deleteIndex()
                    modelContext.delete(project)
                    globalStore.currentTab = nil
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
        }
    }
    
    @ViewBuilder
    func ContentView() -> some View {
        TabView(selection: $selectedTab) {
            
            ProjectChatView(chats: project.chats)
                .tag(ProjectViewTab.chat)
                .tabItem{
                    Text("Chats")
                }
            
            ProjectFileView(project: project)
                .tag(ProjectViewTab.file)
                .tabItem{
                    Text("Files")
                }.toolbar {
                    Menu("Add", systemImage: "plus") {
                        Button("Choose Folder", systemImage: "folder") {
                            folderImporterPresented = true
                        }
                        Button("Add Files", systemImage: "doc.badge.plus") {
                            resourceImporterPresented = true
                        }
                    }
                }
            
        }.tabViewStyle(.grouped)
        
    }

    private func addDroppedItems(_ urls: [URL]) {
        var resources: [URL] = []
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                project.workingDirectory = url.standardizedFileURL
            } else {
                resources.append(url)
            }
        }
        project.addResources(resources)
    }
}

#Preview(traits: .preview) {
    ProjectView(project: .preview)
}
