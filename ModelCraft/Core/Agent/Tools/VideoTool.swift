//
//  VideoTool.swift
//  ModelCraft
//
//  Created by Hongshen on 15/4/26.
//

import Foundation
import UniformTypeIdentifiers

import MLXLMCommon

class VideoTool {
    
    static var allTools: [any ToolProtocol] { [textToVideo] }

    private static let evaluator = LTXVideoEvaluator()
    
    static var textToVideo: Tool<textToVideoInput, textToVideoOutput> {
        Tool<textToVideoInput, textToVideoOutput>(
            name: "text_to_video",
            description: "Generate an LTX Video clip from a text prompt with an explicit aspect ratio, long-edge resolution, and duration",
            parameters: [
                .required("prompt", type: .string, description: "Description of the video and motion"),
                .required(
                    "ratio",
                    type: .string,
                    description: "Output aspect ratio",
                    extraProperties: [
                        "enum": LTXVideoAspectRatio.allCases.map(\.rawValue)
                    ]),
                .required(
                    "resolution",
                    type: .int,
                    description: "Approximate output long edge",
                    extraProperties: [
                        "enum": LTXVideoResolution.allCases.map(\.rawValue),
                        "x-recommended": LTXVideoResolution.deviceRecommendation.rawValue,
                    ]),
                .required(
                    "duration_seconds",
                    type: .int,
                    description: "Output duration in seconds",
                    extraProperties: [
                        "minimum": LTXVideoEvaluateParameters.minimumDurationSeconds,
                        "maximum": LTXVideoEvaluateParameters.maximumDurationSeconds,
                    ])
            ]
        ) { input in
            let type = UTType.mpeg4Movie
            let url = URL.moviesDirectory.appendingPathComponent(UUID().uuidString, conformingTo: type)
            guard let ratio = LTXVideoAspectRatio(rawValue: input.ratio) else {
                throw LTXVideoToolError.unsupportedRatio(input.ratio)
            }
            guard let resolution = LTXVideoResolution(rawValue: input.resolution) else {
                throw LTXVideoToolError.unsupportedResolution(input.resolution)
            }
            guard input.durationSeconds >= LTXVideoEvaluateParameters.minimumDurationSeconds,
                  input.durationSeconds <= LTXVideoEvaluateParameters.maximumDurationSeconds else {
                throw LTXVideoToolError.unsupportedDuration(input.durationSeconds)
            }
            let frames = try await evaluator.generate(
                prompt: input.prompt,
                ratio: ratio,
                resolution: resolution,
                durationSeconds: input.durationSeconds)
            try LTXVideoIO.saveVideo(
                frames: frames,
                fps: LTXVideoEvaluateParameters.frameRate,
                outputPath: url)
            return textToVideoOutput(
                videoURL: url,
                mimeType: type.preferredMIMEType!
            )
        }
    }

}

struct textToVideoInput: Codable {
    let prompt: String
    let ratio: String
    let resolution: Int
    let durationSeconds: Int

    enum CodingKeys: String, CodingKey {
        case prompt
        case ratio
        case resolution
        case durationSeconds = "duration_seconds"
    }
}

struct textToVideoOutput: Codable {
    let videoURL: URL
    let mimeType: String
}

enum LTXVideoToolError: Error, LocalizedError {
    case unsupportedRatio(String)
    case unsupportedResolution(Int)
    case unsupportedDuration(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedRatio(let ratio):
            "Unsupported LTX Video ratio: \(ratio)"
        case .unsupportedResolution(let resolution):
            "Unsupported LTX Video resolution: \(resolution)"
        case .unsupportedDuration(let duration):
            "Unsupported LTX Video duration: \(duration) seconds"
        }
    }
}
