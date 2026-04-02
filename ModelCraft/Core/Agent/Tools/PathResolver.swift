//
//  PathResolver.swift
//  ModelCraft
//
//  Created by Hongshen on 31/3/26.
//

import Foundation

struct PathResolver {
    
    /// Resolves a potentially relative path from an LLM into a full, absolute Sandbox URL.
    /// - Parameter path: The path string provided by the LLM (could be relative or absolute).
    /// - Returns: A validated absolute file URL within the App's Documents directory.
    static func resolve(_ path: String) -> URL {
        let rootPath = URL.documentsDirectory.path()
        if path.hasPrefix(rootPath) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: rootPath).appendingPathComponent(path)
    }
    
}
