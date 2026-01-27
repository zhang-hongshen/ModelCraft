//
//  FileTool.swift
//  ModelCraft
//
//  Created by Hongshen on 26/1/26.
//

import Foundation

class FileTool {
    
    static func resolvePath(_ path: String) -> URL {
        let sandboxRootPath: String = {
            let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            return paths[0].path
        }()
        if path.hasPrefix(sandboxRootPath) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: sandboxRootPath).appendingPathComponent(path)
    }

    static func writeToFile(_ path: String, content: String) throws {
        let url = resolvePath(path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let data = content.data(using: .utf8)!
        try data.write(to: url, options: .atomic)
    }

    static func readFromFile(_ path: String) throws -> String {
        let url = resolvePath(path)
            let data = try Data(contentsOf: url)
        return String(decoding: data, as: UTF8.self)
    }
    
    @discardableResult
    static func executeCommand(
        _ command: String
    ) throws -> String {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sh", "-c", command]
        process.currentDirectoryURL = resolvePath("")
        
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        
        try process.run()
        process.waitUntilExit()
        
        
        let outputData = try stdout.fileHandleForReading.readToEnd()
        let errorData = try stderr.fileHandleForReading.readToEnd()
        
        let output = (outputData.flatMap { String(data: $0, encoding: .utf8)} ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let error = errorData.flatMap { String(data: $0, encoding: .utf8) } ?? nil
        if let error = error {
            throw RuntimeError(error)
        }
        return output
        
    }
    
}
