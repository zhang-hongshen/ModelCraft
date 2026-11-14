//
//  GlobalStore.swift
//  ModelCraft
//
//  Created by Hongshen on 26/2/25.
//

import SwiftUI

@MainActor
@Observable
class GlobalStore {
    /// The app's one store, shared with tools that run outside the view hierarchy.
    static let shared = GlobalStore()

    var selectedModel: LocalModel? = nil
    var currentTab: AppNavigationTab? = nil
    var newThreadProject: Project? = nil
    var runningTasks: [String: Task<Void, Never>] = [:]
    /// The file shown in the window's trailing inspector.
    var previewURL: URL? = nil
    var isInspectorPresented = false
    /// Files for the new thread's composer to attach, handed over from outside it: dropped on
    /// the Dock icon or a sidebar row, or opened from Finder.
    var newThreadFiles: [URL] = []
    /// A message for the new thread to send as soon as it shows, from Quick Entry.
    var newThreadPrompt: ThreadRequest? = nil

    struct ThreadRequest: Equatable {
        let content: String
        let files: [URL]
    }

    func startNewThread(in project: Project? = nil) {
        newThreadProject = project
        currentTab = nil
    }

    func startNewThread(in project: Project? = nil, attaching files: [URL]) {
        startNewThread(in: project)
        newThreadFiles.append(contentsOf: files)
    }
}
