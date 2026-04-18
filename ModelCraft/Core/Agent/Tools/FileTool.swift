//
//  FileTool.swift
//  ModelCraft
//
//  Created by Hongshen on 26/1/26.
//

import Foundation

import MLXLMCommon

class FileTool {

    static let allTools = [
        writeToFile.schema,
        readFromFile.schema
    ]
    
    static func writeToFile(_ path: String, content: String) throws {
        let url = PathResolver.resolve(path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let data = content.data(using: .utf8)!
        try data.write(to: url, options: .atomic)
    }
    
    static func readFromFile(_ path: String) throws -> String {
        let url = PathResolver.resolve(path)
            let data = try Data(contentsOf: url)
        return String(decoding: data, as: UTF8.self)
    }
    
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

struct WriteToFileOutput: Codable {}
