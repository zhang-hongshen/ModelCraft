//
//  GlobalStore.swift
//  ModelCraft
//
//  Created by Hongshen on 2/26/25.
//

import SwiftUI

@Observable
class GlobalStore {
    var selectedModel: LocalModel? = nil
    var currentTab: AppNavigationTab? = nil
    var runningTasks: [String: Task<Void, Never>] = [:]
}
