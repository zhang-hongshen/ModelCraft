//
//  AudioTool.swift
//  ModelCraft
//
//  Created by Hongshen on 24/5/26.
//

import UniformTypeIdentifiers
import MLXLMCommon


class AudioTool {
    
    static let allTools = [
        textToAudio.schema
    ]
    
    static let textToAudio = Tool<textToAudioInput, textToAudioOutput>(
            name: "text_to_audio",
            description: "Generate an audio from text prompt",
            parameters: [
                .required("prompt", type: .string, description: "Description of the audio")
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
