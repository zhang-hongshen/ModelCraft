//
//  FileManager+.swift
//  Arthub
//
//  Created by 张鸿燊 on 21/2/2024.
//

import Foundation

extension FileManager {
    
    func fileExists(at: URL) -> Bool {
        return FileManager.default.fileExists(atPath: at.relativePath)
    }
    
    func createDirectoryIfNotExists(at: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(at: at) {
            try fileManager.createDirectory(at: at, withIntermediateDirectories: true)
        }
    }
    
}
