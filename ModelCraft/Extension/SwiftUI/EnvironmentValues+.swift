//
//  EnvironmentValues+.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 26/3/2024.
//

import SwiftUI

// implement enum server status
enum ServerStatus: String {
    case disconnected
    case starting
    case connected
    
    
    // implement localized name
    var localizedName: LocalizedStringKey {
        switch self {
        case .disconnected: "Disconnected"
        case .starting: "Starting"
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

extension EnvironmentValues {
    var serverStatus: Binding<ServerStatus> {
        get { self[ServerStatusKey.self] }
        set { self[ServerStatusKey.self] = newValue }
    }
    
    var downaloadedModels: [ModelInfo] {
        get { self[DownaloadedModelKey.self] }
        set { self[DownaloadedModelKey.self] = newValue }
    }
}
