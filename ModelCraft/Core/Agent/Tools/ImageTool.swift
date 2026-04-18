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
    
    static let allTools = [
        textToImage.schema
    ]
    
    static let textToImage = Tool<textToImageInput, textToImageOutput?>(
            name: "text_to_image",
            description: "Generate an image from text prompt",
            parameters: [
                .required("prompt", type: .string, description: "Description of the image")
            ]
        ) { input in
            let evaluator = await StableDiffusionEvaluator()
            let image = try await evaluator.generate(prompt: input.prompt)
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
