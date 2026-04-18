//
//  SkillTool.swift
//  ModelCraft
//
//  Created by Hongshen on 31/3/26.
//

import Foundation

import MLXLMCommon

class SkillTool {
    
    static let allTools = [
        activateSkill.schema
    ]
    
    static var activateSkill: Tool<ActivateSkillInput, ActivateSkillOutput> {
        let availableSkills = SkillManager.shared.skillCatalogPrompt()
        return Tool<ActivateSkillInput, ActivateSkillOutput>(
            name: "activate_skill",
            description:
            """
                Activate a skill to load its instructions.
                \(availableSkills)
            """,
            parameters: [
                .required("name", type: .string, description: "Skill name")
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
