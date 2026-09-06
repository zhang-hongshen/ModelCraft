//
//  AudioTool.swift
//  ModelCraft
//
//  Created by Hongshen on 24/5/26.
//

import Foundation
import UniformTypeIdentifiers
import MLXLMCommon


enum AudioTool {
    
    static let allTools: [any ToolProtocol] = [
        textToAudio
    ]
    
    static let textToAudio = Tool<TextToAudioInput, TextToAudioOutput>(
            name: "text_to_audio",
            description: "Generate a new WAV music or audio clip from a text description with the local audio model. Saves the file in the configured audio output directory and returns its file URL and MIME type.",
            parameters: [
                .required("prompt", type: .string, description: "Describe the desired sound, including genre or source, mood, instruments, rhythm, and other audible qualities that matter.")
            ]
        ) { input in
            try Task.checkCancellation()
            let evaluator = await MusicGenEvaluator()
            let type = UTType.wav
            let outputDirectory = UserDefaults.standard.url(forKey: UserDefaults.audioOutputDirectory)
                ?? UserDefaultSettings.audioOutputDirectory
            let url = outputDirectory.appendingPathComponent(UUID().uuidString, conformingTo: type)
            let audio = try await evaluator.generate(prompt: input.prompt)
            try Task.checkCancellation()
            do {
                try await evaluator.saveAudio(to: url, audio: audio)
                try Task.checkCancellation()
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            return TextToAudioOutput(
                audioURL: url,
                mimeType: type.preferredMIMEType!
            )
        }
}

struct TextToAudioInput: Codable {
    let prompt: String
}

struct TextToAudioOutput: Codable {
    let audioURL: URL
    let mimeType: String
}
