//
//  CallToolResult.swift
//  ModelCraft
//
//  Created by Hongshen on 26/1/26.
//


import Foundation

/// Represents the result of a tool call
struct CallToolResult: Codable {
    
    /// The primary content blocks returned by the tool (Text, Image, etc.).
    var content: [ContentBlock]
    
    /// Optional structured data for machine-to-machine communication.
    var structuredContent: Value?
    
    /// Indicates if the tool execution encountered an error.
    var isError: Bool?

    // Custom coding keys to handle the underscore and dynamic fields
    enum CodingKeys: String, CodingKey {
        case content, structuredContent, isError
    }
    
    static func error(_ error: String) -> CallToolResult{
        return CallToolResult(content: [.text(.init(text: error))], isError: true)
    }
    
    static func error(_ error: Error) -> CallToolResult{
        return CallToolResult(content: [.text(.init(text: error.localizedDescription))], isError: true)
    }
}

/// MCP Content Block types
enum ContentBlock: Codable {
    case text(TextContent)
    case image(ImageContent)
    case audio(AudioContent)
    case resourceLink(ResourceLink)
    case embeddedResource(EmbeddedResource)

    enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text": self = .text(try TextContent(from: decoder))
        case "image": self = .image(try ImageContent(from: decoder))
        case "audio": self = .audio(try AudioContent(from: decoder))
        case "resource_link": self = .resourceLink(try ResourceLink(from: decoder))
        case "embedded_resource": self = .embeddedResource(try EmbeddedResource(from: decoder))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown content type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let content): try container.encode(content)
        case .image(let content): try container.encode(content)
        case .audio(let content): try container.encode(content)
        case .resourceLink(let content): try container.encode(content)
        case .embeddedResource(let content): try container.encode(content)
        }
    }
}

// Individual content structures
struct TextContent: Codable {
    var type: String = "text"
    let text: String
}

struct ImageContent: Codable {
    var type: String = "image"
    let data: String
    let mimeType: String
}

struct AudioContent: Codable {
    var type: String = "audio"
    let data: String
    let mimeType: String
}

struct ResourceLink: Codable {
    var type: String = "resource_link"
    let name: String
    let title: String
    let uri: String
    let description: String?
    let mimeType: String?
    let size: Int?
}

struct EmbeddedResource: Codable {
    var type: String = "resource"
    let resource: Resource
}

enum Resource: Codable {
    case text(TextResourceContent)
    case blob(BlobResourceContent)
}

struct TextResourceContent: Codable {
    let uri: String
    let text: String
    let mimeType: String?
}

struct BlobResourceContent: Codable {
    let uri: String
    let blob: String
    let mimeType: String?
    
}
