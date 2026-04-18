//
//  VideoTool.swift
//  ModelCraft
//
//  Created by Hongshen on 15/4/26.
//

import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

import MLXLMCommon

class VideoTool {
    
    static let allTools = [
        textToVideo.schema
    ]
    
    static let textToVideo = Tool<textToVideoInput, textToVideoOutput>(
            name: "text_to_video",
            description: "Generate a video from text prompt",
            parameters: [
                .required("prompt", type: .string, description: "Description of the video")
            ]
        ) { input in
            let evaluator = await WanEvaluator()
            let type = UTType.mpeg4Movie
            let url = URL.moviesDirectory.appendingPathComponent(UUID().uuidString, conformingTo: type)
            try await evaluator.generate(prompt: input.prompt, outputPath: url)
            return textToVideoOutput(
                videoURL: url,
                mimeType: type.preferredMIMEType!
            )
        }
}

struct textToVideoInput: Codable {
    let prompt: String
}

struct textToVideoOutput: Codable {
    let videoURL: URL
    let mimeType: String
}
