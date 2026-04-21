//
//  FileManager+.swift
//  ModelCraft
//
//  Created by Hongshen on 21/2/2024.
//

import Foundation

extension FileManager {
    
    func fileExists(at: URL) -> Bool {
        return self.fileExists(atPath: at.path())
    }
    
    func createDirectoryIfNotExists(at: URL) throws {
        if !fileExists(at: at) {
            try createDirectory(at: at, withIntermediateDirectories: true)
        }
    }
    
}
