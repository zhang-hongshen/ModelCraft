//
//  AudioTool.swift
//  ModelCraft
//
//  Created by Hongshen on 24/5/26.
//

import UniformTypeIdentifiers
import MLXLMCommon


class AudioTool {
    
    static let allTools: [any ToolProtocol] = [
        textToAudio
    ]
    
    static let textToAudio = Tool<textToAudioInput, textToAudioOutput>(
            name: "text_to_audio",
            description: "Generate a new WAV music or audio clip from a text description with the local audio model. Saves the file in the Music directory and returns its file URL and MIME type.",
            parameters: [
                .required("prompt", type: .string, description: "Describe the desired sound, including genre or source, mood, instruments, rhythm, and other audible qualities that matter.")
            ]
        ) { input in
            let evaluator = await MusicGenEvaluator()
            let type = UTType.wav
            let url = URL.musicDirectory.appendingPathComponent(UUID().uuidString, conformingTo: type)
            try await evaluator.saveAudio(to: url, audio: try await evaluator.generate(prompt: input.prompt))
            return textToAudioOutput(
                audioURL: url,
                mimeType: type.preferredMIMEType!
            )
        }
}

struct textToAudioInput: Codable {
    let prompt: String
}

struct textToAudioOutput: Codable {
    let audioURL: URL
    let mimeType: String
}
