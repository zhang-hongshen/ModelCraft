//
//  SkillDiscovery.swift
//  ModelCraft
//
//  Created by Hongshen on 8/3/26.
//

import Foundation


final class SkillDiscovery {
    
    func discoverSkills(at root: URL) -> [URL] {
        
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [] }
        
        var skills: [URL] = []
        
        for case let url as URL in enumerator {
            if url.lastPathComponent == "SKILL.md" {
                skills.append(url)
            }
        }
        
        return skills
    }
}
