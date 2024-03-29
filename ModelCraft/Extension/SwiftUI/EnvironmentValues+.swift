//
//  EnvironmentValues+.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 26/3/2024.
//

import SwiftUI
import OllamaKit

// implement enum server status
enum ServerStatus: String {
    
    case disconnected, launching, connected
    
    // implement localized name
    var localizedDescription: LocalizedStringKey {
        switch self {
        case .disconnected: "Disconnected"
        case .launching: "Launching"
        case .connected: "Connected"
        }
    }
}

private struct ServerStatusKey: EnvironmentKey {
    static var defaultValue: Binding<ServerStatus> = .constant(.disconnected)
}

private struct DownaloadedModelKey: EnvironmentKey {
    static var defaultValue: [ModelInfo] = []
}

private struct ModelTaskKey: EnvironmentKey {
    static var defaultValue: [ModelTask] = []
}

private struct SelectedModelKey: EnvironmentKey {
    static var defaultValue: Binding<ModelInfo?> = .constant(nil)
}

extension EnvironmentValues {
    
    var serverStatus: Binding<ServerStatus> {
        get { self[ServerStatusKey.self] }
        set { self[ServerStatusKey.self] = newValue }
    }
    
    var downaloadedModels: [ModelInfo] {
        get { self[DownaloadedModelKey.self] }
        set { self[DownaloadedModelKey.self] = newValue }
    }
    
    var modelTasks: [ModelTask] {
        get { self[ModelTaskKey.self] }
        set { self[ModelTaskKey.self] = newValue }
    }
    
    var selectedModel: Binding<ModelInfo?> {
        get { self[SelectedModelKey.self] }
        set { self[SelectedModelKey.self] = newValue }
    }
}
