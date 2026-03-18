//
//  SkillManager.swift
//  ModelCraft
//
//  Created by Hongshen on 8/3/26.
//

import Foundation

class SkillManager {
    
    static let shared = SkillManager()
    
    private(set) var skills: [String: Skill] = [:]
    
    private let discovery = SkillDiscovery()
    private let parser = SkillParser()
    
    func loadSkills() async{
        
        let paths = [
            Bundle.main.resourceURL!.appendingPathComponent("Skills"),
            URL.applicationSupportDirectory.appendingPathComponent("Skills")
        ]
        for path in paths {
            
            let skillFiles = discovery.discoverSkills(at: path)
            
            for file in skillFiles {
                do {
                    let skill = try parser.parse(url: file)
                    skills[skill.name] = skill
                } catch {
                    print("skill parse error", error)
                }
            }
        }
    }
}

extension SkillManager {
    
    func skillCatalogPrompt() -> String {
            
        let skillCatalog = skills.values.map {
                """
                <skill>
                    <name>\($0.name)</name>
                    <description>\($0.description)</description>
                </skill>
                """
            }.joined(separator: "\n")
        
        return """
        <available_skills>
        \(skillCatalog)
        </available_skills>
        """
    }
    
    func activateSkill(name: String) -> String? {
            
        guard let skill = skills[name] else {
            return nil
        }
        
        return """
        <skill_content name="\(skill.name)">
        
        \(skill.body ?? "")
        
        Skill directory:
        \(skill.location.deletingLastPathComponent().path)
        Relative paths in this skill are relative to the skill directory.
        </skill_content>
        """
    }
}
