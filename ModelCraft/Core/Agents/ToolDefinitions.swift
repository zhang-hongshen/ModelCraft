//
//  ToolDefinitions.swift
//  ModelCraft
//
//  Created by Hongshen on 25/2/26.
//

import Foundation
import SwiftData

import MLXLMCommon
import Tokenizers


struct ToolDefinition {
    
    static let allTools: [ToolSpec] = [
        readFromFile.schema,
        writeToFile.schema,
        executeCommand.schema,
        captureScreen.schema,
    ]
    
    static let readFromFile = Tool<ReadFromFileInput, ReadFromFileOutput>(
        name: "read_from_file",
        description: "Reads and returns the complete text content from a file at a specified path.",
        parameters: [
            .required("path", type: .string, description: "The absolute or relative path of the file to be read.")
        ]
    ){ input in
        let content = try FileTool.readFromFile(input.path)
        return ReadFromFileOutput(content: content)
    }
    
    static let writeToFile = Tool<WriteToFileInput, WriteToFileOutput>(
        name: "write_to_file",
        description: "Writes text content to a file. It creates the file if it doesn't exist or overwrites it if it already exists.",
        parameters: [
            .required("path", type: .string, description: "The file path where the content should be saved."),
            .required("content", type: .string, description: "The string content to write into the file.")
        
        ]
    ) { input in
        try FileTool.writeToFile(input.path, content: input.content)
        return WriteToFileOutput()
    }
    
    static let executeCommand = Tool<ExecuteCommandInput, ExecuteCommandOutput>(
        name: "execute_command",
        description: "Executes a shell command",
        parameters: [
            .required("command", type: .string, description: "The full shell command string to execute (e.g., 'ls -la' or 'git status').")
        
        ]
    ) { input in
        
        let result = try FileTool.executeCommand(input.command)
        return ExecuteCommandOutput(
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode)
    }
    
    static let searchMap = Tool<SearchMapInput, SearchMapOutput>(
        name: "search_map",
        description: "Search for points of interest, restaurants, or locations nearby or in a specific area.",
        parameters: [
            .required("query", type: .string, description: "The search keyword."),
            .required("useCurrentLocation", type: .bool, description: "Set to true if the user implies their current location. Set to false if a specific city or remote location is mentioned."),
            .optional("numOfResults",
                      type: .int,
                      description: "The maximum number of results to return. Defaults to 5 if not specified.")
        
        ]
    ) { input in
        
        let places = try await SearchTool.searchMap(
            query: input.query,
            useCurrentLocation: input.useCurrentLocation,
            numOfResults: input.numOfResults ?? 5)
        return SearchMapOutput(places: places)
    }
    
    static func createSearchRelevantDocuments(knowledgeBaseID: PersistentIdentifier) -> Tool<SearchRelevantDocumentsInput, SearchRelevantDocumentsOutput>{
        return Tool(
            name: "search_relevant_documents",
            description: "Search for information in the user's uploaded documents.",
            parameters: [
                .required("query", type: .string, description: "The keyword or question to search for in the document database."),
            ]
        ) { input in
            let knowledgaBaseModelActor = KnowledgaBaseModelActor(modelContainer: SwiftData.ModelContainer.shared)
            let docs = await knowledgaBaseModelActor.searchRelevantDocuments(knowledgeBaseID: knowledgeBaseID, query: input.query)
            return SearchRelevantDocumentsOutput(docs: docs)
        }
    }
    
    static let captureScreen = Tool<CaptureScreenInput, CaptureScreenOutput?>(
        name: "capture_screen",
        description: "Takes a high-resolution screenshot of the current screen to analyze the UI layout and identify element coordinates.",
        parameters: []
    ) { input in
        guard let (image, mimeType) = await ScreenControlManager.shared.taskScreenshot() else { return nil }
        return CaptureScreenOutput(image: image, mimeType: mimeType)
    }
    
    static let click = Tool<ClickInput, ClickOutput>(
        name: "click",
        description: "Simulates a mouse click at the specified (x, y) coordinates. Coordinates should be based on the screenshot provided.",
        parameters: [
            .required("x", type: .double, description: "The target x coordinate."),
            .required("y", type: .double, description: "The target y coordinate.")
        ]
    ) { input in
        await ScreenControlManager.shared.click(x: input.x, y: input.y)
        return ClickOutput()
    }
    
    static let move = Tool<MoveInput, MoveOutput>(
        name: "move",
        description: "Moves the mouse cursor to a specific (x, y) location without clicking.",
        parameters: [
            .required("x", type: .double, description: "The target x coordinate."),
            .required("y", type: .double, description: "The target y coordinate.")
        ]
    ) { input in
        await ScreenControlManager.shared.move(x: input.x, y: input.y)
        return MoveOutput()
    }
}

struct ReadFromFileInput: Codable {
    let path: String
}

struct ReadFromFileOutput: Codable {
    let content: String
}


struct WriteToFileInput: Codable {
    let path: String
    let content: String
}

struct WriteToFileOutput: Codable {
    
}


struct ExecuteCommandInput: Codable {
    let command: String
}

struct ExecuteCommandOutput: Codable {
    let stdout: String
    let stderr: String
    let exitCode: Int
}

struct SearchMapInput: Codable {
    let query: String
    let useCurrentLocation: Bool
    let numOfResults: Int?
}

struct SearchMapOutput: Codable {
    let places: [MapPlace]
}

struct SearchRelevantDocumentsInput: Codable {
    let query: String
    let numOfResults: Int?
}

struct SearchRelevantDocumentsOutput: Codable {
    let docs: [String]
}


struct CaptureScreenInput: Codable {
}

struct CaptureScreenOutput: Codable {
    
    let imageBase64: String
    let mimeType: String
    
    init(image: Data, mimeType: String) {
        self.imageBase64 = image.base64EncodedString()
        self.mimeType = mimeType
    }
}

struct MoveInput: Codable {
    let x: Double
    let y: Double
}

struct MoveOutput: Codable {
}


struct ClickInput: Codable {
    let x: Double
    let y: Double
}

struct ClickOutput: Codable {
}
