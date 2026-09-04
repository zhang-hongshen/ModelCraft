//
//  GlobalStore.swift
//  ModelCraft
//
//  Created by Hongshen on 2/26/25.
//

import SwiftUI

@MainActor
@Observable
class GlobalStore {
    var selectedModel: LocalModel? = nil
    var currentTab: AppNavigationTab? = nil
    var newChatProject: Project? = nil
    var runningTasks: [String: Task<Void, Never>] = [:]

    func startNewChat(in project: Project? = nil) {
        newChatProject = project
        currentTab = nil
    }
}
