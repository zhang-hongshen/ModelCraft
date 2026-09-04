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

class ImageTool {
    
    static let allTools: [any ToolProtocol] = [
        textToImage
    ]
    
    static let textToImage = Tool<textToImageInput, textToImageOutput>(
            name: "text_to_image",
            description: "Generate a new PNG image from a text description with the local image model. Saves the image in the Pictures directory and returns its file URL and MIME type.",
            parameters: [
                .required("prompt", type: .string, description: "Describe the desired image, including subject, composition, style, lighting, colors, and any visible text that matter.")
            ]
        ) { input in
            let image = try await StableDiffusionEvaluator.shared.generate(prompt: input.prompt)
            let type = UTType.png
            let url = URL.picturesDirectory.appendingPathComponent(UUID().uuidString, conformingTo: type)
            image.save(to: url)
            return textToImageOutput(
                imageURL: url,
                mimeType: type.preferredMIMEType!
            )
        }
}

struct textToImageInput: Codable {
    let prompt: String
}

struct textToImageOutput: Codable {
    let imageURL: URL
    let mimeType: String
}
