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
    var newChatProject: Project? = nil
    var runningTasks: [String: Task<Void, Never>] = [:]
    /// The file shown in the window's trailing inspector.
    var previewURL: URL? = nil
    var isInspectorPresented = false
    /// Files for the new chat's composer to attach, handed over from outside it: dropped on
    /// the Dock icon or a sidebar row, or opened from Finder.
    var newChatFiles: [URL] = []
    /// A message for the new chat to send as soon as it shows, from Quick Entry.
    var newChatPrompt: ChatRequest? = nil

    struct ChatRequest: Equatable {
        let content: String
        let files: [URL]
    }

    func startNewChat(in project: Project? = nil) {
        newChatProject = project
        currentTab = nil
    }

    func startNewChat(in project: Project? = nil, attaching files: [URL]) {
        startNewChat(in: project)
        newChatFiles.append(contentsOf: files)
    }
}
