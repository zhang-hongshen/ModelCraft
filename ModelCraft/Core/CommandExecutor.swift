//
//  CommandExecutor.swift
//  ModelCraft
//
//  Created by Hongshen on 5/1/26.
//

import Foundation

enum CommandExecutor {
    
    @discardableResult
        static func run(
            _ command: URL?,
            arguments: [String] = [],
            onFinished: @escaping ((String, String?) -> Void)
        ) throws -> Process {

            let process = Process()
            process.executableURL = command
            process.arguments = arguments
            process.standardInput = nil

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let text = String(data: data, encoding: .utf8)
                else { return }
                onFinished(text, nil)
            }
            
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let error = String(data: data, encoding: .utf8)
                else { return }
                onFinished("", error)
            }

            process.terminationHandler = { _ in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
            }

            try process.run()
            return process
        }
    
}
