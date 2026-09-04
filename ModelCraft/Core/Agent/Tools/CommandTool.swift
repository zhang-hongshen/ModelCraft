//
//  CommandTool.swift
//  ModelCraft
//
//  Created by Hongshen on 31/3/26.
//

import Foundation

import MLXLMCommon

class CommandTool {
    
    #if os(macOS)
    static let allTools: [any ToolProtocol] = [
        executeCommand
    ]
    #else
    static let allTools: [any ToolProtocol] = []
    #endif
    
#if os(macOS)
    @discardableResult
    static func executeCommand(
        _ command: String
    ) async throws -> CommandResult {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sh", "-c", command]
        process.currentDirectoryURL = .documentsDirectory
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        
        try process.run()
        process.waitUntilExit()
        
        let outputData = try stdoutPipe.fileHandleForReading.readToEnd()
        let errorData = try stderrPipe.fileHandleForReading.readToEnd()
        
        let stdout = outputData.flatMap { String(data: $0, encoding: .utf8)} ?? ""
        let stderr = errorData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return CommandResult(stdout: stdout, stderr: stderr, exitCode: Int(process.terminationStatus))
    }
    
    static let executeCommand = Tool<ExecuteCommandInput, ExecuteCommandOutput>(
        name: "execute_command",
        description: "Run one shell command from the app's Documents directory on macOS. The command may read or modify local files and returns stdout, stderr, and the process exit code.",
        parameters: [
            .required("command", type: .string, description: "The complete command string passed to `sh -c`. Use paths relative to the Documents directory or explicit absolute paths, and include every required argument.")
        
        ]
    ) { input in
        
        let result = try await CommandTool.executeCommand(input.command)
        return ExecuteCommandOutput(
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode)
    }
#endif
}

struct CommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int
}


struct ExecuteCommandInput: Codable {
    let command: String
}

struct ExecuteCommandOutput: Codable {
    let stdout: String
    let stderr: String
    let exitCode: Int
}
