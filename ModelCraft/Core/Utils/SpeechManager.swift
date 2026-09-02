//
//  SpeechManager.swift
//  ModelCraft
//
//  Created by Hongshen on 20/1/26.
//


import AVFoundation
import NaturalLanguage
import SwiftUI

@MainActor
@Observable
class SpeechManager: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    
    var isSpeaking: Bool = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, rate: Float, volume: Float) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        utterance.volume = volume
        
        utterance.voice = AVSpeechSynthesisVoice(language: language.rawValue)
        
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    // MARK: - Delegate Methods
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = true
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = false
        }
    }
    
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = false
        }
    }
}
