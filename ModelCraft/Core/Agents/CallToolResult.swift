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
    var isError: Bool

    // Custom coding keys to handle the underscore and dynamic fields
    enum CodingKeys: String, CodingKey {
        case content, structuredContent, isError
    }
    
    init?(json: String) {
        guard let data = json.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
        do {
            self = try JSONDecoder().decode(CallToolResult.self, from: data)
        } catch {
//            debugPrint("Invalid Tool Call: \(error.localizedDescription)")
            return nil
        }
    }
    
    init(content: [ContentBlock] = [], structuredContent: Value? = nil, isError: Bool) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
    }
    
    static func success(content: [ContentBlock] = []) -> CallToolResult {
        return self.success(content: content, structuredContent: nil)
    }
    
    static func success(content: [ContentBlock] = [], structuredContent: Value? = nil) -> CallToolResult {
        return CallToolResult(content: content, structuredContent: structuredContent, isError: false)
    }
    
    static func error(_ error: Error) -> CallToolResult{
        return self.error(error.localizedDescription)
    }
    
    static func error(_ error: String) -> CallToolResult{
        return CallToolResult(content: [.text(TextContent(text: error))], isError: true)
    }
    
}

/// Content Block types
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
        let type = try container.decode(ContentType.self, forKey: .type)
        switch type {
        case .text: self = .text(try TextContent(from: decoder))
        case .image: self = .image(try ImageContent(from: decoder))
        case .audio: self = .audio(try AudioContent(from: decoder))
        case .resourceLink: self = .resourceLink(try ResourceLink(from: decoder))
        case .embeddedResource: self = .embeddedResource(try EmbeddedResource(from: decoder))
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

enum ContentType: String, Codable {
    case text, image, audio
    case embeddedResource = "resource"
    case resourceLink =  "resource_link"
}

struct Annotations: Codable {
    let audience: [MessageRole]?
    let priority: Int?
    let lastModified: String?
    
    init(audience: [MessageRole]? = nil, priority: Int? = nil, lastModified: String? = nil) {
        self.audience = audience
        self.priority = priority
        self.lastModified = lastModified
    }
}

// Individual content structures
struct TextContent: Codable {
    var type: ContentType
    let text: String
    let annotations: Annotations?
    
    init(text: String, annotations: Annotations? = nil) {
        self.type = .text
        self.text = text
        self.annotations = annotations
    }
}

struct ImageContent: Codable {
    let type: ContentType
    let data: String
    let mimeType: String
    let annotations: Annotations?
    
    init(data: String, mimeType: String, annotations: Annotations? = nil) {
        self.type = .image
        self.data = data
        self.mimeType = mimeType
        self.annotations = annotations
    }
    
}

struct AudioContent: Codable {
    let type: ContentType
    let data: String
    let mimeType: String
    let annotations: Annotations?
    
    init(data: String, mimeType: String, annotations: Annotations? = nil) {
        self.type = .audio
        self.data = data
        self.mimeType = mimeType
        self.annotations = annotations
    }
}

struct ResourceLink: Codable {
    let type: ContentType
    let name: String
    let title: String
    let uri: String
    let description: String?
    let mimeType: String?
    let annotations: Annotations?
    let size: Int?
    
    init(name: String, title: String, uri: String, description: String? = nil,
         mimeType: String? = nil, annotations: Annotations? = nil, size: Int? = nil) {
        self.type = .resourceLink
        self.name = name
        self.title = title
        self.uri = uri
        self.description = description
        self.mimeType = mimeType
        self.annotations = annotations
        self.size = size
    }
    
}

struct EmbeddedResource: Codable {
    let type: ContentType
    let resource: Resource
    let annotations: Annotations?
    
    init(resource: Resource, annotations: Annotations? = nil) {
        self.type = .embeddedResource
        self.resource = resource
        self.annotations = annotations
    }
}

enum Resource: Codable {
    case text(TextResourceContent)
    case blob(BlobResourceContent)
}

struct TextResourceContent: Codable {
    let uri: String
    let text: String
    let mimeType: String?
    
    init(uri: String, text: String, mimeType: String? = nil) {
        self.uri = uri
        self.text = text
        self.mimeType = mimeType
    }
}

struct BlobResourceContent: Codable {
    let uri: String
    let blob: String
    let mimeType: String?
    
    init(uri: String, blob: String, mimeType: String? = nil) {
        self.uri = uri
        self.blob = blob
        self.mimeType = mimeType
    }
}
