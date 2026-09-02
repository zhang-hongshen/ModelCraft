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
    
    @State private var fileImporterPresented: Bool = false
    @State private var selectedTab: ProjectViewTab = .chat
    @State private var projectEditionPresented: Bool = false
    
    @Environment(GlobalStore.self)private var globalStore
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        ContentView()
            .padding(.top)
            .toolbar(content: ToolbarItems)
            .fileImporter(isPresented: $fileImporterPresented,
                          allowedContentTypes: [.data, .folder],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    project.addFiles(urls)
                case .failure(let error):
                    print(error.localizedDescription)
                }
            }
            .sheet(isPresented: $projectEditionPresented){
              ProjectEdition(project: project)
            }
            .dropDestination(for: URL.self) { items, location in
                project.addFiles(items)
                return true
            }
    }
}

extension ProjectView {
    
    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        
        ToolbarItemGroup(placement: .primaryAction){
            Button("Add Files", systemImage: "doc.badge.plus") {
                fileImporterPresented = true
            }
            Menu {
                
                Button("Edit") {
                    projectEditionPresented = true
                }
                DeleteButton(style: .iconAndText) {
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
                    Button("Add Files", systemImage: "doc.badge.plus") {
                        fileImporterPresented = true
                    }
                }
            
        }.tabViewStyle(.grouped)
        
    }
}

#Preview(traits: .preview) {
    ProjectView(project: .preview)
}
