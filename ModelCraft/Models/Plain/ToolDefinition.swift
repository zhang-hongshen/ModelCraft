//
//  ToolDefinition.swift
//  ModelCraft
//
//  Created by Hongshen on 12/1/26.
//

import Foundation

struct ToolDefinitions {
    
    static let allTools: [Tool] = [
        readFromFile,
        writeToFile,
        executeCommand
    ]
    
    // MARK: - 1. Read From File
    private static let readFromFile = Tool(
        name: "read_from_file",
        description: "Reads and returns the complete text content from a file at a specified path.",
        inputSchema: InputSchema(
            type: "object",
            properties: [
                "path": Property(
                    type: "string",
                    description: "The absolute or relative path of the file to be read.")
                ],
            required: ["path"]
        )
    )
    
    // MARK: - 2. Write To File
    private static let writeToFile = Tool(
        name: "write_to_file",
        description: "Writes text content to a file. It creates the file if it doesn't exist or overwrites it if it already exists.",
        inputSchema: InputSchema(
            type: "object",
            properties: [
                "path": Property(
                    type: "string",
                    description: "The file path where the content should be saved."),
                "content": Property(
                    type: "string",
                    description: "The string content to write into the file.")
                ],
            required: ["path", "content"]
        )
    )
    
    // MARK: - 3. Execute Command
    private static let executeCommand = Tool(
        name: "execute_command",
        description: "Executes a shell command on the host system and returns its standard output and error messages.",
        inputSchema: InputSchema(
            type: "object",
            properties: [
                "command": Property(
                    type: "string",
                    description: "The full shell command string to execute (e.g., 'ls -la' or 'git status').")
            ],
            required: ["command"]
        )
    )
}
