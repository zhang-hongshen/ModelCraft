//
//  SkillTool.swift
//  ModelCraft
//
//  Created by Hongshen on 31/3/26.
//

import Foundation

import MLXLMCommon

class SkillTool {
    
    static let allTools: [any ToolProtocol] = [
        activateSkill
    ]
    
    static var activateSkill: Tool<ActivateSkillInput, ActivateSkillOutput> {
        let availableSkills = SkillManager.shared.skillCatalogPrompt()
        return Tool<ActivateSkillInput, ActivateSkillOutput>(
            name: "activate_skill",
            description:
            """
                Load the full instructions for one available specialized skill. Use this before performing a task covered by a listed skill, then follow the returned instructions for the rest of that task.
                \(availableSkills)
            """,
            parameters: [
                .required("name", type: .string, description: "The exact name of one skill listed in this tool's description.")
            ]
        ) { input in
            
            let skillText = SkillManager.shared.activateSkill(name: input.name)
            
            return ActivateSkillOutput(content: skillText ?? "")
        }
    }
}

struct ActivateSkillInput: Codable {
    let name: String
}

struct ActivateSkillOutput: Codable {
    let content: String
}
