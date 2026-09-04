//
//  ToolDefinitions.swift
//  ModelCraft
//
//  Created by Hongshen on 25/2/26.
//

import Foundation
import MLXLMCommon
import Tokenizers

struct ToolDefinition {

    static let modelIDs: Set<String> = [
        StableDiffusionConfiguration.presetSDXLTurbo.id,
        LTXVideoConfiguration.ltxv2BDistilled.id,
        MusicGenConfiguration.small.id,
        MusicGenConfiguration.small.audioEncoderParameters.id,
        MusicGenConfiguration.small.textEncoderParameters.id,
    ]
    
    static var allTools: [any ToolProtocol] = [
        DecisionTool.allTools,
        FileTool.allTools,
        SearchTool.allTools,
        CommandTool.allTools,
        ImageTool.allTools,
        VideoTool.allTools,
        AudioTool.allTools,
        ComputerUseTool.allTools,
        ScreenControlTool.allTools,
        SkillTool.allTools
    ].flatMap{ $0 }
    
    @MainActor
    static var allToolSchema: [ToolSpec] {
        var tools = allTools.map { $0.schema }
        if NetworkMonitor.shared.isConnected {
            tools.append(WebTool.webFetch.schema)
        }
        return tools
    }
    
}

struct DecisionTool {

    static let allTools: [any ToolProtocol] = [requestDecision]

    static let requestDecision = Tool<RequestDecisionInput, RequestDecisionInput>(
        name: ToolNames.requestDecision,
        description: "Use this tool when continuing requires the user to provide missing information, choose among options, or make a decision that should not be inferred.",
        parameters: [
            .required(
                "questions",
                type: .array(elementType: .object(properties: [
                    .required("id", type: .string, description: "Stable identifier for this question"),
                    .required("question", type: .string, description: "Question shown to the user"),
                    .required(
                        "options",
                        type: .array(elementType: .object(properties: [
                            .required("id", type: .string, description: "Stable option identifier"),
                            .required("label", type: .string, description: "Short option label"),
                            .optional("description", type: .string, description: "Brief explanation of the option")
                        ])),
                        description: "Options offered for this question"),
                    .optional(
                        "recommended_option_id",
                        type: .string,
                        description: "Option identifier to preselect when one option is recommended")
                ])),
                description: "Decisions to present together")
        ]
    ) { input in
        input
    }
}

struct RequestDecisionInput: Codable, Sendable {
    let questions: [DecisionQuestion]
}

struct DecisionQuestion: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let question: String
    let options: [DecisionOption]
    let recommendedOptionID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case question
        case options
        case recommendedOptionID = "recommended_option_id"
    }
}

struct DecisionOption: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let label: String
    let description: String?
}

struct RequestDecisionOutput: Codable, Sendable {
    let answers: [DecisionAnswer]
}

struct DecisionAnswer: Codable, Sendable {
    let questionID: String
    let selectedOptionID: String?
    let customAnswer: String?

    enum CodingKeys: String, CodingKey {
        case questionID = "question_id"
        case selectedOptionID = "selected_option_id"
        case customAnswer = "custom_answer"
    }
}
