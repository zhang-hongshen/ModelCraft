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
}

struct InputSchema: Codable {
    let type: String
    let properties: [String: Property]
    let required: [String]
}

struct Property: Codable {
    let type: String
    let description: String
}
