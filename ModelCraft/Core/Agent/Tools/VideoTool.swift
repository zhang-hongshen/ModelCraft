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
    
    static let allTools: [any ToolProtocol] = [
        textToVideo
    ]

    private static let evaluator = H3Evaluator()
    
    static let textToVideo = Tool<textToVideoInput, textToVideoOutput>(
            name: "text_to_video",
            description: "Generate a MiniMax H3 video from text, first/last frames, or ordered image/video/audio references",
            parameters: [
                .required("prompt", type: .string, description: "Description of the video and motion"),
                .optional("first_frame", type: .string, description: "Path to the image that should be the first video frame"),
                .optional("last_frame", type: .string, description: "Path to the image that should be the last video frame"),
                .optional("reference_files", type: .array(elementType: .string), description: "Ordered local image, video, or audio paths for H3-Base-Ref2VA; do not combine with first_frame or last_frame"),
                .optional("duration_seconds", type: .int, description: "Video duration in seconds, from 5 to 15; defaults to 5"),
                .optional("width", type: .int, description: "Output width, a multiple of 32; defaults to 1344"),
                .optional("height", type: .int, description: "Output height, a multiple of 32; defaults to 768"),
                .optional("steps", type: .int, description: "Sampling steps; defaults to 20"),
                .optional("seed", type: .int, description: "Non-negative random seed; defaults to 0")
            ]
        ) { input in
            let type = UTType.mpeg4Movie
            let url = URL.moviesDirectory.appendingPathComponent(UUID().uuidString, conformingTo: type)
            let references = try (input.referenceFiles ?? []).map { try reference(at: $0) }
            let request = H3EvaluatorRequest(
                prompt: input.prompt,
                videoOutput: url,
                firstFrame: input.firstFrame.map(PathResolver.resolve),
                lastFrame: input.lastFrame.map(PathResolver.resolve),
                references: references,
                durationSeconds: input.durationSeconds ?? 5,
                width: input.width ?? 1344,
                height: input.height ?? 768,
                steps: input.steps ?? 20,
                seed: input.seed.flatMap { $0 >= 0 ? UInt64($0) : nil } ?? 0)
            try await evaluator.generate(request)
            return textToVideoOutput(
                videoURL: url,
                mimeType: type.preferredMIMEType!
            )
        }

    private static func reference(at path: String) throws -> H3Reference {
        let url = PathResolver.resolve(path)
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            throw H3EvaluatorError.invalidRequest(
                rule: "unknown reference media type",
                detail: url.lastPathComponent,
                remedy: "use a local image, video, or audio file with a recognized extension.")
        }
        if type.conforms(to: .image) { return .image(url) }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video(url) }
        if type.conforms(to: .audio) { return .audio(url) }
        throw H3EvaluatorError.invalidRequest(
            rule: "unsupported reference media type",
            detail: url.lastPathComponent,
            remedy: "use a local image, video, or audio file.")
    }
}

struct textToVideoInput: Codable {
    let prompt: String
    let firstFrame: String?
    let lastFrame: String?
    let referenceFiles: [String]?
    let durationSeconds: Int?
    let width: Int?
    let height: Int?
    let steps: Int?
    let seed: Int?

    enum CodingKeys: String, CodingKey {
        case prompt
        case firstFrame = "first_frame"
        case lastFrame = "last_frame"
        case referenceFiles = "reference_files"
        case durationSeconds = "duration_seconds"
        case width
        case height
        case steps
        case seed
    }
}

struct textToVideoOutput: Codable {
    let videoURL: URL
    let mimeType: String
}
