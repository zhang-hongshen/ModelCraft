//
//  CommandTool.swift
//  ModelCraft
//
//  Created by Hongshen on 31/3/26.
//

import Foundation

import MLXLMCommon
import Tokenizers

class CommandTool {
    
    #if os(macOS)
    static let allTools: [ToolSpec] = [
        executeCommand.schema
    ]
    #else
    static let allTools: [ToolSpec] = []
    #endif
    
#if os(macOS)
    @discardableResult
    static func executeCommand(
        _ command: String
    ) throws -> CommandResult {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sh", "-c", command]
        process.currentDirectoryURL = PathResolver.resolve("")
        
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
        description: "Executes a shell command",
        parameters: [
            .required("command", type: .string, description: "The full shell command string to execute (e.g., 'ls -la' or 'git status').")
        
        ]
    ) { input in
        
        let result = try CommandTool.executeCommand(input.command)
        return ExecuteCommandOutput(
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode)
    }
#endif
}

struct CommandResult {
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
