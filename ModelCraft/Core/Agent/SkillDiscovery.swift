//
//  SkillDiscovery.swift
//  ModelCraft
//
//  Created by Hongshen on 8/3/26.
//

import Foundation


enum SkillDiscovery {
    
    static func discoverSkills(at root: URL) -> [URL] {
        let directories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return (directories ?? [])
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .map { $0.appendingPathComponent("SKILL.md") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
