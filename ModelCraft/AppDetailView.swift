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
        case .chat, .none:
            let chat = selectedChat
            ChatView(chat: chat)
                .navigationTitle(chat?.title ?? String(localized: "New Chat"))
        case .modelStore:
            ModelStore().navigationTitle("Model Store")
        case .downloadedModels:
            DownloadedModelsView().navigationTitle("Downloaded Models")
        }
    }

    private var selectedChat: Chat? {
        guard case .chat(let chat) = tab else { return nil }
        return chat
    }
}

#Preview(traits: .preview) {
    AppDetailView(tab: nil)
}
