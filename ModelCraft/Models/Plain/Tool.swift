//
//  Tool.swift
//  ModelCraft
//
//  Created by Hongshen on 21/1/26.
//

public struct Tool: Codable {
    let name: String
    let description: String
    let inputSchema: InputSchema
    let outputSchema: OutputSchema?
    
    init(name: String, description: String,
         inputSchema: InputSchema, outputSchema: OutputSchema? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
    }
}

struct InputSchema: Codable {
    let type: String
    let properties: [String: Property]
    let required: [String]
}

struct OutputSchema: Codable {
    let type: String
    let properties: [String: Property]
    let required: [String]
}

struct Property: Codable {
    let type: String
    let description: String
}
