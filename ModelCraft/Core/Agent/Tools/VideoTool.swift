//
//  VideoTool.swift
//  ModelCraft
//
//  Created by Hongshen on 15/4/26.
//

import Foundation
import UniformTypeIdentifiers

import MLXLMCommon

enum VideoTool {
    
    static var allTools: [any ToolProtocol] {
        selectedModelID.isEmpty ? [] : [textToVideo]
    }

    private static let evaluator = LTXVideoEvaluator()
    private static let h3Evaluator = H3Evaluator()
    private static var selectedModelID: String {
        UserDefaults.standard.string(forKey: UserDefaults.videoGenerationModelID) ?? "ltx-video"
    }
    private static var usesH3: Bool { selectedModelID == "minimax-h3" }
    
    static var textToVideo: Tool<TextToVideoInput, TextToVideoOutput> {
        let usesH3 = Self.usesH3
        var parameters: [ToolParameter] = [
            .required("prompt", type: .string, description: "Describe the subject, scene, visual style, camera behavior, and motion over time."),
        ]
        if !usesH3 {
            parameters.append(contentsOf: [
                .required(
                    "ratio",
                    type: .string,
                    description: "The output frame's width-to-height aspect ratio. Use one of the enumerated string values.",
                    extraProperties: ["enum": LTXVideoAspectRatio.allCases.map(\.rawValue)]),
                .required(
                    "resolution",
                    type: .int,
                    description: "Approximate pixel count of the output frame's longer edge. Use an enumerated value.",
                    extraProperties: [
                        "enum": LTXVideoResolution.allCases.map(\.rawValue),
                        "x-recommended": LTXVideoResolution.deviceRecommendation.rawValue,
                    ]),
            ])
        }
        parameters.append(.required(
            "duration",
            type: .int,
            description: "Requested video duration in whole seconds.",
            extraProperties: [
                "minimum": usesH3 ? 5 : LTXVideoEvaluateParameters.minimumDuration,
                "maximum": usesH3 ? 15 : LTXVideoEvaluateParameters.maximumDuration,
            ]))

        return Tool<TextToVideoInput, TextToVideoOutput>(
            name: "text_to_video",
            description: usesH3
                ? "Generate an MP4 video with the selected MiniMax H3 model. H3 produces video at its supported 768p canvas. Saves the file in this chat's folder and returns its file URL and MIME type. The app shows the generated file to the user, so do not repeat its path."
                : "Generate an MP4 video with the selected LTX Video model. Before calling this tool, ask the user with request_user_input to choose aspect ratio, long-edge resolution, and duration. Saves the file in this chat's folder and returns its file URL and MIME type. The app shows the generated file to the user, so do not repeat its path.",
            parameters: parameters
        ) { input in
            let type = UTType.mpeg4Movie
            let url = ProjectToolContext.chatDirectory.appendingPathComponent(UUID().uuidString, conformingTo: type)
            guard input.duration >= (usesH3 ? 5 : LTXVideoEvaluateParameters.minimumDuration),
                  input.duration <= (usesH3 ? 15 : LTXVideoEvaluateParameters.maximumDuration) else {
                throw LTXVideoToolError.unsupportedDuration(input.duration)
            }
            if usesH3 {
                await ToolExecutionProgressReporter.videoGeneration?(.preparing)
                let request = H3EvaluatorRequest(
                    prompt: input.prompt,
                    videoOutput: url,
                    duration: input.duration)
                _ = try await h3Evaluator.generate(request)
                return TextToVideoOutput(videoURL: url, mimeType: type.preferredMIMEType!)
            }
            guard let ratioValue = input.ratio,
                  let ratio = LTXVideoAspectRatio(rawValue: ratioValue) else {
                throw LTXVideoToolError.unsupportedRatio(input.ratio ?? "")
            }
            guard let resolutionValue = input.resolution,
                  let resolution = LTXVideoResolution(rawValue: resolutionValue) else {
                throw LTXVideoToolError.unsupportedResolution(input.resolution ?? 0)
            }
            let frames = try await evaluator.generate(
                prompt: input.prompt,
                ratio: ratio,
                resolution: resolution,
                duration: input.duration
            ) { progress in
                await ToolExecutionProgressReporter.videoGeneration?(progress)
            }
            try Task.checkCancellation()
            await ToolExecutionProgressReporter.videoGeneration?(.writing)
            try Task.checkCancellation()
            try await LTXVideoIO.saveVideo(
                frames: frames,
                fps: LTXVideoEvaluateParameters.frameRate,
                outputPath: url)
            return TextToVideoOutput(
                videoURL: url,
                mimeType: type.preferredMIMEType!
            )
        }
    }

}

struct TextToVideoInput: Codable {
    let prompt: String
    let ratio: String?
    let resolution: Int?
    let duration: Int

    enum CodingKeys: String, CodingKey {
        case prompt
        case ratio
        case resolution
        case duration = "duration"
    }
}

struct TextToVideoOutput: Codable {
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
