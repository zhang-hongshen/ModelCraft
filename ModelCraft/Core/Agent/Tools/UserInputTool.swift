//
//  UserInputTool.swift
//  ModelCraft
//
//  Created by Hongshen on 5/9/26.
//

import Foundation
import MLXLMCommon

struct UserInputTool {

    static let allTools: [any ToolProtocol] = [requestUserInput]

    static let requestUserInput = Tool<RequestUserInput, RequestUserInput>(
        name: ToolNames.requestUserInput,
        description: "Use this tool when the user must provide missing information, choose among multiple valid options, enter text, or select a file or directory before continuing. Do not infer a preference when the answer affects the result. Group related inputs into one request. This tool gathers information only; execution permission is handled separately by the app. It returns each field_id with values containing selected option IDs, entered text, or selected absolute paths.",
        parameters: [
            .required(
                "fields",
                type: .array(elementType: .object(properties: [
                    .required("id", type: .string, description: "Stable identifier used to match this field with its returned answer."),
                    .required("label", type: .string, description: "Concise question or label shown to the user."),
                    .required(
                        "type",
                        type: .string,
                        description: "UI control to present. Use single_choice or multiple_choice with options, text or multiline_text for typed input, file to select existing files, or directory to select folders.",
                        extraProperties: [
                            "enum": UserInputFieldType.allCases.map(\.rawValue)
                        ]),
                    .optional("description", type: .string, description: "Additional context that helps the user answer."),
                    .optional("placeholder", type: .string, description: "Placeholder shown by text and multiline_text fields."),
                    .optional(
                        "options",
                        type: .array(elementType: .object(properties: [
                            .required("id", type: .string, description: "Stable option identifier"),
                            .required("label", type: .string, description: "Short option label"),
                            .optional("description", type: .string, description: "Brief explanation of the option")
                        ])),
                        description: "Choices offered by single_choice and multiple_choice fields.",
                        extraProperties: ["minItems": 2]),
                    .optional(
                        "recommended_option_id",
                        type: .string,
                        description: "Option identifier to mark as recommended without selecting it for the user."),
                    .optional(
                        "allows_custom_answer",
                        type: .bool,
                        description: "Set to true when a choice field should also let the user enter an answer outside the listed options."),
                    .optional(
                        "allows_multiple_selection",
                        type: .bool,
                        description: "Set to true when a file or directory field should allow selecting multiple items.")
                ])),
                description: "One or more related inputs to present together.",
                extraProperties: ["minItems": 1])
        ]
    ) { input in
        input
    }
}

struct RequestUserInput: Codable, Sendable {
    let fields: [UserInputField]
}

enum UserInputFieldType: String, Codable, CaseIterable, Sendable {
    case singleChoice = "single_choice"
    case multipleChoice = "multiple_choice"
    case text
    case multilineText = "multiline_text"
    case file
    case directory
}

struct UserInputField: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let label: String
    let type: UserInputFieldType
    let description: String?
    let placeholder: String?
    let options: [UserInputOption]?
    let recommendedOptionID: String?
    let allowsCustomAnswer: Bool?
    let allowsMultipleSelection: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case type
        case description
        case placeholder
        case options
        case recommendedOptionID = "recommended_option_id"
        case allowsCustomAnswer = "allows_custom_answer"
        case allowsMultipleSelection = "allows_multiple_selection"
    }
}

struct UserInputOption: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let label: String
    let description: String?
}

struct RequestUserInputOutput: Codable, Sendable {
    let answers: [UserInputAnswer]
}

struct UserInputAnswer: Codable, Sendable {
    let fieldID: String
    let values: [String]

    enum CodingKeys: String, CodingKey {
        case fieldID = "field_id"
        case values
    }
}
