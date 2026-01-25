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
        executeCommand,
        composeEmail,
        composeMessage,
        openBrowser
    ]
    
    // MARK: - Read From File
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
    
    // MARK: - Write To File
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
    
    // MARK: - Execute Command
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
    
    // MARK: - Compose Email
    private static let composeEmail = Tool(
        name: "compose_email",
        description: "Triggers the default mail client to compose an email. This opens a draft window for the user to review and send manually.",
        inputSchema: InputSchema(
            type: "object",
            properties: [
                "recipients": Property(
                    type: "array",
                    description: "A list of recipient email addresses (To field)."
                ),
                "subject": Property(
                    type: "string",
                    description: "The subject line of the email."
                ),
                "body": Property(
                    type: "string",
                    description: "The plain text content of the email body."
                ),
            ],
            required: ["recipients", "subject", "body"]
        )
    )
    
    // MARK: - Compose Message Tool
    private static let composeMessage = Tool(
        name: "compose_message",
        description: "Opens the Messages app to send a text message to one or more recipients.",
        inputSchema: InputSchema(
            type: "object",
            properties: [
                "recipients": Property(type: "array", description: "Phone numbers."),
                "body": Property(type: "string", description: "The content of the message.")
            ],
            required: ["recipients", "body"]
        )
    )
    
    // MARK: - Open Browser Tool
    private static let openBrowser = Tool(
        name: "open_browser",
        description: "Opens a specific URL in the default web browser.",
        inputSchema: InputSchema(
            type: "object",
            properties: [
                "url": Property(type: "string", description: "The full URL to open (starting with http:// or https://).")
            ],
            required: ["url"]
        )
    )
}
