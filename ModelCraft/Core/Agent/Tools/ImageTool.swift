//
//  ImageTool.swift
//  ModelCraft
//
//  Created by Hongshen on 7/4/26.
//

import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

import MLXLMCommon

enum ImageTool {
    
    static let allTools: [any ToolProtocol] = [
        textToImage
    ]
    
    static let textToImage = Tool<TextToImageInput, TextToImageOutput>(
            name: "text_to_image",
            description: "Generate a new PNG image from a text description with the local image model. Saves the image in the configured image output directory and returns its file URL and MIME type.",
            parameters: [
                .required("prompt", type: .string, description: "Describe the desired image, including subject, composition, style, lighting, colors, and any visible text that matter.")
            ]
        ) { input in
            try Task.checkCancellation()
            let image = try await StableDiffusionEvaluator.shared.generate(
                prompt: input.prompt
            ) { progress in
                await ToolExecutionProgressReporter.imageGeneration?(progress)
            }
            try Task.checkCancellation()
            await ToolExecutionProgressReporter.imageGeneration?(.saving)
            try Task.checkCancellation()
            let type = UTType.png
            let outputDirectory = UserDefaults.standard.url(forKey: UserDefaults.imageOutputDirectory)
                ?? UserDefaultSettings.imageOutputDirectory
            let url = outputDirectory.appendingPathComponent(UUID().uuidString, conformingTo: type)
            var completed = false
            defer {
                if !completed {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            image.save(to: url)
            try Task.checkCancellation()
            completed = true
            return TextToImageOutput(
                imageURL: url,
                mimeType: type.preferredMIMEType!
            )
        }
}

struct TextToImageInput: Codable {
    let prompt: String
}

struct TextToImageOutput: Codable {
    let imageURL: URL
    let mimeType: String
}
