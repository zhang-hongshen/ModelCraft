//
//  EnvironmentValues+.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 26/3/2024.
//

import SwiftUI
import OllamaKit
import AVFoundation

extension EnvironmentValues {
    
    @Entry var downaloadedModels: [ModelInfo] = []
    @Entry var speechSynthesizer: AVSpeechSynthesizer  = AVSpeechSynthesizer()
}


enum ServerStatus: String {
    
    case disconnected, launching, connected
    
    var localizedDescription: LocalizedStringKey {
        switch self {
        case .disconnected: "Disconnected"
        case .launching: "Launching"
        case .connected: "Connected"
        }
    }
}

class GlobalStore: ObservableObject {
    @Published var serverStatus: ServerStatus = .disconnected
    @Published var selectedModel: String? = nil
    @Published var errorWrapper: ErrorWrapper? = nil
}
