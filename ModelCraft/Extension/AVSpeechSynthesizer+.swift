//
//  AVSpeechSynthesizer+.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 31/3/2024.
//

import AVFoundation
import NaturalLanguage

extension AVSpeechSynthesizer {
    func speak(_ text: String) {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return }
        
        if isSpeaking {
            pauseSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language.rawValue)
        utterance.rate = 0.5
        speak(utterance)
    }
}
