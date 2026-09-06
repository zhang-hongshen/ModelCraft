//
//  SkillParser.swift
//  ModelCraft
//
//  Created by Hongshen on 8/3/26.
//

import Foundation

enum SkillParser {
    
    static func parse(url: URL) throws -> Skill {
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closingIndex = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else {
            throw SkillParserError.missingFrontmatter
        }

        let yaml = lines[1..<closingIndex].joined(separator: "\n")
        let bodyStart = lines.index(after: closingIndex)
        let body = bodyStart < lines.endIndex
            ? lines[bodyStart...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let metadata = parseYAML(yaml)
        guard let name = metadata["name"], isValidName(name) else {
            throw SkillParserError.invalidName
        }
        guard let description = metadata["description"], !description.isEmpty else {
            throw SkillParserError.missingDescription
        }
        guard name == url.deletingLastPathComponent().lastPathComponent else {
            throw SkillParserError.nameDoesNotMatchDirectory
        }

        return Skill(
            name: name,
            description: description,
            location: url,
            body: body
        )
    }
    
    private static func parseYAML(_ text: String) -> [String: String] {
        var dict: [String: String] = [:]
        
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                dict[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                unquoted(String(parts[1]).trimmingCharacters(in: .whitespaces))
            }
        }
        
        return dict
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              first == value.last,
              first == "\"" || first == "'" else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    private static func isValidName(_ name: String) -> Bool {
        guard name.count <= 64 else { return false }
        return name.range(
            of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#,
            options: .regularExpression
        ) != nil
    }
}

enum SkillParserError: LocalizedError {
    case missingFrontmatter
    case invalidName
    case missingDescription
    case nameDoesNotMatchDirectory

    var errorDescription: String? {
        switch self {
        case .missingFrontmatter:
            "SKILL.md must begin with YAML frontmatter."
        case .invalidName:
            "Skill name must use lowercase letters, numbers, and single hyphens."
        case .missingDescription:
            "Skill description is required."
        case .nameDoesNotMatchDirectory:
            "Skill name must match its directory name."
        }
    }
}
