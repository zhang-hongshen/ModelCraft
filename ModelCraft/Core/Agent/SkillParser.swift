//
//  SkillParser.swift
//  ModelCraft
//
//  Created by Hongshen on 8/3/26.
//

import Foundation

struct SkillParser {
    
    func parse(url: URL) throws -> Skill {
        
        let text = try String(contentsOf: url)
        
        let parts = text.components(separatedBy: "---")
        
        guard parts.count >= 3 else {
            throw NSError(domain: "SkillParse", code: 1)
        }
        
        let yaml = parts[1]
        let body = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        
        let metadata = parseYAML(yaml)
        
        return Skill(
            name: metadata["name"] ?? "unknown",
            description: metadata["description"] ?? "",
            location: url,
            body: body
        )
    }
    
    private func parseYAML(_ text: String) -> [String: String] {
        var dict: [String: String] = [:]
        
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                dict[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        
        return dict
    }
}
