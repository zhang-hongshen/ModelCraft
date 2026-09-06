//
//  SkillManager.swift
//  ModelCraft
//
//  Created by Hongshen on 8/3/26.
//

import Foundation

final class SkillManager {
    
    static let shared = SkillManager()
    
    private(set) var skills: [String: Skill] = [:]
    
    func loadSkills() {
        var loadedSkills: [String: Skill] = [:]

        for path in skillDirectories {
            let skillFiles = SkillDiscovery.discoverSkills(at: path)
            for file in skillFiles {
                do {
                    let skill = try SkillParser.parse(url: file)
                    loadedSkills[skill.name] = skill
                } catch {
                    print("Skill parse error at \(file.path): \(error.localizedDescription)")
                }
            }
        }

        skills = loadedSkills
    }

    private var skillDirectories: [URL] {
        var directories: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            directories.append(resourceURL.appendingPathComponent("Skills"))
        }

        directories.append(UserDefaultSettings.skillDirectory)
        directories.append(contentsOf: UserDefaults.standard
            .stringArray(forKey: UserDefaults.customSkillDirectories)?
            .map { URL(fileURLWithPath: $0).standardizedFileURL } ?? [])

        var seenPaths: Set<String> = []
        return directories.filter {
            seenPaths.insert($0.standardizedFileURL.path).inserted
        }
    }
}

extension SkillManager {
    
    func skillCatalogPrompt() -> String {
            
        let skillCatalog = skills.values.sorted { $0.name < $1.name }.map {
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
