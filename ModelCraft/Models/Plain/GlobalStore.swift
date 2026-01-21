//
//  GlobalStore.swift
//  ModelCraft
//
//  Created by Hongshen on 2/26/25.
//

import SwiftUI

@Observable
class GlobalStore {
    var serverStatus: ServerStatus = .disconnected
    var selectedModel: String? = nil
    var errorWrapper: ErrorWrapper? = nil
    var selectedKnowledgeBase: KnowledgeBase? = nil
    var currentTab: Tab? = nil
}
