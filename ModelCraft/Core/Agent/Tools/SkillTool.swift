//
//  SkillTool.swift
//  ModelCraft
//
//  Created by Hongshen on 31/3/26.
//

import Foundation

import MLXLMCommon

enum SkillTool {
    
    static var allTools: [any ToolProtocol] { [activateSkill] }
    
    static var activateSkill: Tool<ActivateSkillInput, ActivateSkillOutput> {
        SkillManager.shared.loadSkills()
        let availableSkills = SkillManager.shared.skillCatalogPrompt()
        return Tool<ActivateSkillInput, ActivateSkillOutput>(
            name: "activate_skill",
            description:
            """
                Load the full instructions for one available specialized skill. Use this before performing a task covered by a listed skill, then follow the returned instructions for the rest of that task.
                A /<skill-name> reference anywhere in a user message explicitly requests that exact skill; load every referenced skill before handling the request.
                \(availableSkills)
            """,
            parameters: [
                .required("name", type: .string, description: "The exact name of one skill listed in this tool's description.")
            ]
        ) { input in
            try Task.checkCancellation()
            guard let skillText = SkillManager.shared.activateSkill(name: input.name) else {
                throw SkillToolError.skillNotFound(input.name)
            }
            try Task.checkCancellation()
            return ActivateSkillOutput(content: skillText)
        }
    }
}

enum SkillToolError: LocalizedError {
    case skillNotFound(String)

    var errorDescription: String? {
        switch self {
        case .skillNotFound(let name):
            "Skill not found: \(name)"
        }
    }
}

struct ActivateSkillInput: Codable {
    let name: String
}

struct ActivateSkillOutput: Codable {
    let content: String
}
