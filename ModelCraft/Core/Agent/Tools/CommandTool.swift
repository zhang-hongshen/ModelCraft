//
//  CommandTool.swift
//  ModelCraft
//
//  Created by Hongshen on 31/3/26.
//

import Foundation

import MLXLMCommon

enum ProjectToolContext {
    @TaskLocal static var workingDirectory: URL?
    @TaskLocal static var readOnlyFiles: [URL] = []
}

enum CommandTool {

    static let allTools: [any ToolProtocol] = [
        executeCommand
    ]

    @discardableResult
    static func executeCommand(
        _ command: String
    ) async throws -> CommandResult {
        try Task.checkCancellation()
        if !ReadOnlyCommandPolicy.allows(command),
           ProjectToolContext.readOnlyFiles.contains(where: {
               command.contains($0.standardizedFileURL.path)
           }) {
            throw CommandToolError.readOnlyReference
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sh", "-c", command]
        process.currentDirectoryURL = ProjectToolContext.workingDirectory ?? .documentsDirectory
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        try process.run()

        let outputTask = Task.detached {
            try stdoutPipe.fileHandleForReading.readToEnd()
        }
        let errorTask = Task.detached {
            try stderrPipe.fileHandleForReading.readToEnd()
        }
        let terminationTask = Task.detached {
            process.waitUntilExit()
            return Int(process.terminationStatus)
        }

        return try await withTaskCancellationHandler {
            let outputData = try await outputTask.value
            let errorData = try await errorTask.value
            let exitCode = await terminationTask.value
            try Task.checkCancellation()

            let stdout = outputData.flatMap { String(data: $0, encoding: .utf8)} ?? ""
            let stderr = errorData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return CommandResult(stdout: stdout, stderr: stderr, exitCode: exitCode)
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }
    }
    
    static let executeCommand = Tool<ExecuteCommandInput, ExecuteCommandOutput>(
        name: "execute_command",
        description: "Run one shell command from the current project's working folder, or the app's Documents directory when the project has no working folder. The command may read or modify files in the working folder and returns stdout, stderr, and the process exit code. Project reference files are read-only and must not be changed or deleted.",
        parameters: [
            .required("command", type: .string, description: "The complete command string passed to `sh -c`. Use paths relative to the current working folder or explicit absolute paths, include every required argument, and never modify a project reference file.")
        
        ]
    ) { input in
        
        let result = try await CommandTool.executeCommand(input.command)
        return ExecuteCommandOutput(
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode)
    }
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

enum CommandToolError: LocalizedError {
    case readOnlyReference

    var errorDescription: String? {
        "Project reference files are read-only."
    }
}
