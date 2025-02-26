//
//  AVSpeechSynthesizer+.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 31/3/2024.
//

import AVFoundation
import NaturalLanguage
import SwiftUI

extension AVSpeechSynthesizer {
    
    func speak(_ text: String, rate: Float, volume: Float) {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return }
        
        if isSpeaking {
            stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language.rawValue)
        utterance.rate = rate
        utterance.volume = volume
        speak(utterance)
    }
    
    func stop() {
        stopSpeaking(at: .immediate)
    }
}
