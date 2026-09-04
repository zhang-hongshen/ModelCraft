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
            description: "Generate a new MP4 video clip from a text description with the local video model. Requires an explicit aspect ratio, long-edge resolution, and duration, saves the file in the Movies directory, and returns its file URL and MIME type.",
            parameters: [
                .required("prompt", type: .string, description: "Describe the subject, scene, visual style, camera behavior, and motion over time."),
                .required(
                    "ratio",
                    type: .string,
                    description: "The output frame's width-to-height aspect ratio. Use one of the enumerated string values.",
                    extraProperties: [
                        "enum": LTXVideoAspectRatio.allCases.map(\.rawValue)
                    ]),
                .required(
                    "resolution",
                    type: .int,
                    description: "Approximate pixel count of the output frame's longer edge. Use an enumerated value; prefer the recommended value unless the user requests another size.",
                    extraProperties: [
                        "enum": LTXVideoResolution.allCases.map(\.rawValue),
                        "x-recommended": LTXVideoResolution.deviceRecommendation.rawValue,
                    ]),
                .required(
                    "duration",
                    type: .int,
                    description: "Requested output duration in whole seconds within the minimum and maximum declared by this schema.",
                    extraProperties: [
                        "minimum": LTXVideoEvaluateParameters.minimumDuration,
                        "maximum": LTXVideoEvaluateParameters.maximumDuration,
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
            guard input.duration >= LTXVideoEvaluateParameters.minimumDuration,
                  input.duration <= LTXVideoEvaluateParameters.maximumDuration else {
                throw LTXVideoToolError.unsupportedDuration(input.duration)
            }
            let frames = try await evaluator.generate(
                prompt: input.prompt,
                ratio: ratio,
                resolution: resolution,
                duration: input.duration
            ) { progress in
                await ToolExecutionProgressReporter.videoGeneration?(progress)
            }
            await ToolExecutionProgressReporter.videoGeneration?(.writing)
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
    let duration: Int

    enum CodingKeys: String, CodingKey {
        case prompt
        case ratio
        case resolution
        case duration = "duration"
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
