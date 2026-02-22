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
//        composeEmail,
//        composeMessage,
//        openBrowser,
        searchMap,
        searchRelevantDocuments,
        executeAppleScript,
        captureScreen,
        move,
        click
    ]
    
    // MARK: - Read From File
    private static let readFromFile = Tool(
        name: .readFromFile,
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
        name: .writeToFile,
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
        name: .executeCommand,
        description: "Executes a shell command",
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
        name: .composeEmail,
        description: "Triggers the default mail client to compose an email.",
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
        name: .composeEmail,
        description: "Opens the Messages app to send a text message to one or more recipients.",
        inputSchema: InputSchema(
            type: "object",
            properties: [
                "recipients": Property(
                    type: "array",
                    description: "Phone numbers."),
                "body": Property(
                    type: "string",
                    description: "The content of the message.")
            ],
            required: ["recipients", "body"]
        )
    )
    
    // MARK: - Open Browser Tool
    private static let openBrowser = Tool(
        name: .openBrowser,
        description: "Opens a specific URL in the default web browser.",
        inputSchema: InputSchema(
            type: "object",
            properties: [
                "url": Property(
                    type: "string",
                    description: "The full URL to open (starting with http:// or https://).")
            ],
            required: ["url"]
        )
    )
    
    private static let searchMap = Tool(
        name: .searchMap,
        description: "Search for points of interest, restaurants, or locations nearby or in a specific area.",
        inputSchema: InputSchema(
            type: "object",
            properties: [
                "query": Property(
                    type: "string",
                    description: "The search keyword."
                ),
                "useCurrentLocation": Property(
                    type: "boolean",
                    description: "Set to true if the user implies their current location. Set to false if a specific city or remote location is mentioned."
                ),
                "numOfResults": Property(
                    type: "number",
                    description: "The maximum number of results to return. Defaults to 5 if not specified."
                )
            ],
            required: ["query", "useCurrentLocation"]
        )
    )
    
    private static let searchRelevantDocuments = Tool(
        name: .searchRelevantDocuments,
        description: "Search for information in the user's uploaded documents.",
        inputSchema: InputSchema(
            type: "object",
            properties: [
                "query": Property(
                    type: "string",
                    description: "The keyword or question to search for in the document database."
                )
            ],
            required: ["query"]
        )
    )
    
    private static let executeAppleScript = Tool(
        name: .executeAppleScript,
        description:
            """
            Primary tool for app automation. Use this to: 
            1) Control app-specific features (e.g., play music, create reminders).
            2) Automate GUI actions (e.g., clicking menus, moving windows). 
            """,
        inputSchema: InputSchema(
            type: "object",
            properties: [
                "script": Property(
                    type: "string",
                    description: "The AppleScript code."
                )
            ],
            required: ["script"]
        )
    )
    
    static let captureScreen = Tool(
        name: .captureScreen,
        description: "Takes a high-resolution screenshot of the current screen to analyze the UI layout and identify element coordinates.",
        inputSchema: InputSchema(
            type: "object",
            properties: [:],
            required: []
        )
    )
    
    static let click = Tool(
        name: .click,
        description: "Simulates a mouse click at the specified (x, y) coordinates. Coordinates should be based on the screenshot provided.",
        inputSchema: .init(
            type: "object",
            properties: [
                "x": .init(type: "number", description: "The horizontal coordinate."),
                "y": .init(type: "number", description: "The vertical coordinate.")
            ],
            required: ["x", "y"]
        )
    )
    
    static let move = Tool(
        name: .move,
        description: "Moves the mouse cursor to a specific (x, y) location without clicking.",
        inputSchema: .init(
            type: "object",
            properties: [
                "x": .init(type: "number", description: "The target x coordinate."),
                "y": .init(type: "number", description: "The target y coordinate.")
            ],
            required: ["x", "y"]
        )
    )
}
