//
//  GlobalStore.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 2/26/25.
//

import SwiftUI

class GlobalStore: ObservableObject {
    @Published var serverStatus: ServerStatus = .disconnected
    @Published var selectedModel: String? = nil
    @Published var errorWrapper: ErrorWrapper? = nil
    @Published var selectedKnowledgeBase: KnowledgeBase? = nil
}
