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
    @Environment(GlobalStore.self)private var globalStore
    
    var body: some View {
        ContentView()
            .toolbar(content: ToolbarItems)
            .fileImporter(isPresented: $fileImporterPresented,
                          allowedContentTypes: [.data, .folder],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    urls.forEach { project.files.append($0) }
                case .failure(let error):
                    print(error.localizedDescription)
                }
            }
            .dropDestination(for: URL.self) { items, location in
                project.files.append(contentsOf: items)
                return true
            }
    }
}

extension ProjectView {
    
    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        ToolbarItemGroup {
            Button("Add Files", systemImage: "doc.badge.plus") {
                fileImporterPresented = true
            }
        }
    }
    
    @ViewBuilder
    func ContentView() -> some View {
        TabView(selection: $selectedTab) {
            
            ProjectChatView(chats: project.chats)
                .tag(ProjectViewTab.file)
                .tabItem{
                    Text("Chats")
                }
            
            ProjectFileView(project: project)
                .tag(ProjectViewTab.file)
                .tabItem{
                    Text("Files")
                }
            
        }
    }
}

#Preview {
    ProjectView(project: Project())
        .environment(GlobalStore())
}
