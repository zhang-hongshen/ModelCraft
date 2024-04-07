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
    func speak(_ text: String) {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return }
        
        if isSpeaking {
            pauseSpeaking(at: .immediate)
        }
        @AppStorage(UserDefaults.speakingRate) var speakingRate = 0.5
        @AppStorage(UserDefaults.speakingVolume) var speakingVolume = 0.8
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language.rawValue)
        utterance.rate = Float(speakingRate)
        utterance.volume = Float(speakingVolume)
        speak(utterance)
    }
}
