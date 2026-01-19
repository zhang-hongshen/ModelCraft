//
//  ToolExecutor.swift
//  ModelCraft
//
//  Created by Hongshen on 5/1/26.
//

import Foundation


struct ToolCall: Codable {
    let tool: String
    let parameters: [String: String]
}

class ToolExecutor {
    
    static let shared = ToolExecutor()
    
    func dispatch(json: String) throws -> String {
        guard let data = json.data(using: .utf8),
              let call = try? JSONDecoder().decode(ToolCall.self, from: data) else {
            return "Error: Invalid JSON format in <action>."
        }
        
        var toolCallRes = ""
        switch call.tool {
        case "read_from_file":
            let path = call.parameters["path"] ?? ""
            toolCallRes = try readFromFile(path)
        case "write_to_file":
            let path = call.parameters["path"] ?? ""
            let content = call.parameters["path"] ?? ""
            try writeToFile(path, content: content)
            toolCallRes = "Successfully write to file \(path)"
        case "execute_command":
            guard let command = call.parameters["command"] else { return "" }
            let (output, error) = try executeCommand(command)
            toolCallRes = error == nil ? output : error!
        default:
            toolCallRes = "Error: Tool '\(call.tool)' not found."
        }
        return toolCallRes
    }
}

func writeToFile(_ path: String, content: String) throws {
    let url = URL(fileURLWithPath: path)
    let data = content.data(using: .utf8)!
    try data.write(to: url, options: .atomic)
}

func readFromFile(_ path: String) throws -> String {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    return String(decoding: data, as: UTF8.self)
}

@discardableResult
func executeCommand(
    _ command: String
) throws -> (output: String, error: String?) {

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["sh", "-c", command]

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
    return (output, error)
}
