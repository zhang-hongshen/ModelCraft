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
