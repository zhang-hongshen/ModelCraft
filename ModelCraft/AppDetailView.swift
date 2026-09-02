//
//  AppDetailView.swift
//  ModelCraft
//
//  Created by Hongshen on 16/5/26.
//

import SwiftUI

struct AppDetailView: View {
    
    var tab: AppNavigationTab? = nil
    
    var body: some View {
        switch tab {
        case .chat(let chat):
            ChatView(chat: chat)
                .navigationTitle(chat.title ?? String(localized: "New Chat"))
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

#Preview(traits: .preview) {
    AppDetailView(tab: nil)
}
