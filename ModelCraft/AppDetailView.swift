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
        case .thread, .none:
            let thread = selectedThread
            ThreadView(thread: thread)
                .navigationTitle(thread?.title ?? String(localized: "New Chat"))
        case .modelStore:
            ModelStore().navigationTitle("Model Store")
        case .downloadedModels:
            DownloadedModelsView().navigationTitle("Downloaded")
        case .connectors:
            ConnectorsView().navigationTitle("Connectors")
        case .schedules:
            SchedulesView().navigationTitle("Scheduled")
        }
    }

    private var selectedThread: Thread? {
        guard case .thread(let thread) = tab else { return nil }
        return thread
    }
}

#if DEBUG
#Preview(traits: .preview) {
    AppDetailView(tab: nil)
}
#endif
