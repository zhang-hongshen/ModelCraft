//
//  GlobalStore.swift
//  ModelCraft
//
//  Created by Hongshen on 2/26/25.
//

import SwiftUI

@Observable
class GlobalStore {
    var selectedModel: LMModel? = MLXService.availableModels[0]
    var selectedKnowledgeBase: KnowledgeBase? = nil
    var currentTab: Tab? = nil
}
