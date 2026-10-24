//
//  ConnectorTool.swift
//  ModelCraft
//

import AppKit
import Foundation
import MCP
import MLXLMCommon

/// Tools served by installed connectors over MCP. Installing a connector caches its tool list,
/// so every request offers the same schemas whether or not the connector's app is running.
enum ConnectorTool {

    static func isInstalled(_ connector: Connector) -> Bool {
        FileManager.default.fileExists(atPath: connector.toolsFileURL.path)
    }

    /// Connects to the connector's app, launching it when it is not running, and caches its tools.
    static func install(_ connector: Connector) async throws {
        let tools = try await withClient(for: connector) { client in
            var tools: [MCP.Tool] = []
            var cursor: String?
            repeat {
                let page = try await client.listTools(cursor: cursor)
                tools += page.tools
                cursor = page.nextCursor
            } while cursor != nil
            return tools
        }
        let url = connector.toolsFileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(tools).write(to: url, options: .atomic)
    }

    static func uninstall(_ connector: Connector) throws {
        try FileManager.default.removeItem(at: connector.toolsFileURL)
    }

    static func schemas(of connector: Connector) -> [ToolSpec] {
        installedTools(of: connector).map { tool -> ToolSpec in
            let description = tool.description ?? tool.annotations.title ?? tool.name
            return [
                "type": "function",
                "function": [
                    "name": connector.toolNamePrefix + tool.name,
                    "description": "\(connector.modelDescription)\n\(description)",
                    "parameters": sendable(tool.inputSchema) ?? [String: any Sendable](),
                ] as [String: any Sendable],
            ]
        }
    }

    /// Only tools the connector marks read-only run without the user's approval.
    static func isReadOnly(toolName: String) -> Bool {
        guard let connector = Connector(toolName: toolName) else { return false }
        let name = String(toolName.dropFirst(connector.toolNamePrefix.count))
        return installedTools(of: connector)
            .first { $0.name == name }?
            .annotations.readOnlyHint == true
    }

    static func call(
        _ toolCall: ToolCall,
        connector: Connector
    ) async throws -> (CallToolResult, MLXLMCommon.Chat.Message) {
        let name = String(toolCall.function.name.dropFirst(connector.toolNamePrefix.count))
        let arguments = try JSONDecoder().decode(
            [String: MCP.Value].self,
            from: JSONEncoder().encode(toolCall.function.arguments))
        let response = try await withClient(for: connector) { client in
            let response: (content: [MCP.Tool.Content], isError: Bool?) =
                try await client.callTool(name: name, arguments: arguments)
            return response
        }

        var result = CallToolResult()
        result.isError = response.isError ?? false
        var texts: [String] = []
        for content in response.content {
            switch content {
            case .text(let text, _, _):
                result.content.append(.text(TextContent(text: text)))
                texts.append(text)
            case .image(let data, let mimeType, _, _):
                result.content.append(.image(ImageContent(data: data, mimeType: mimeType)))
                texts.append("[\(mimeType) image]")
            case .audio(let data, let mimeType, _, _):
                result.content.append(.audio(AudioContent(data: data, mimeType: mimeType)))
                texts.append("[\(mimeType) audio]")
            case .resource(let resource, _, _):
                let text = resource.text ?? "[\(resource.mimeType ?? "binary") resource]"
                result.content.append(.text(TextContent(text: text)))
                texts.append("\(resource.uri)\n\(text)")
            case .resourceLink(let uri, let name, let title, let description, let mimeType, _):
                if let url = URL(string: uri) {
                    result.content.append(.resourceLink(ResourceLink(
                        name: name, title: title ?? name, url: url,
                        description: description, mimeType: mimeType)))
                }
                texts.append("\(title ?? name): \(uri)")
            }
        }
        return (result, .tool(texts.joined(separator: "\n")))
    }

    private static func installedTools(of connector: Connector) -> [MCP.Tool] {
        guard let data = try? Data(contentsOf: connector.toolsFileURL) else { return [] }
        return (try? JSONDecoder().decode([MCP.Tool].self, from: data)) ?? []
    }

    /// One connection per operation: the servers are stateless and on the loopback interface.
    private static func withClient<T>(
        for connector: Connector,
        _ body: (MCP.Client) async throws -> T
    ) async throws -> T {
        let endpoint = try await endpoint(of: connector)
        let token = endpoint.token
        let transport = HTTPClientTransport(
            endpoint: endpoint.url,
            streaming: false,
            requestModifier: { request in
                var request = request
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return request
            })
        let client = MCP.Client(
            name: "ModelCraft",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        do {
            do {
                try await client.connect(transport: transport)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // An endpoint file outlives a server that stopped listening.
                throw ConnectorError.serverUnavailable(connector.name)
            }
            let result = try await body(client)
            await client.disconnect()
            return result
        } catch {
            await client.disconnect()
            throw error
        }
    }

    private struct Endpoint: Decodable {
        let url: URL
        let token: String
    }

    /// Launches the app when it is not running and waits for it to rewrite its endpoint file,
    /// so a file left behind by an earlier session is never used.
    private static func endpoint(of connector: Connector) async throws -> Endpoint {
        guard let applicationURL = connector.applicationURL else {
            throw ConnectorError.applicationNotInstalled(connector.name)
        }
        let path = connector.endpointFileURL.path
        if NSRunningApplication.runningApplications(withBundleIdentifier: connector.bundleID).isEmpty {
            let launchDate = Date()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
            var remainingChecks = 50
            while modificationDate(atPath: path) ?? .distantPast < launchDate {
                remainingChecks -= 1
                guard remainingChecks > 0 else {
                    throw ConnectorError.serverUnavailable(connector.name)
                }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ConnectorError.serverUnavailable(connector.name)
        }
        return try JSONDecoder().decode(Endpoint.self, from: data)
    }

    private static func modificationDate(atPath path: String) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date
    }

    /// Chat templates take JSON Schema as nested Swift values.
    private static func sendable(_ value: MCP.Value) -> (any Sendable)? {
        switch value {
        case .null: nil
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        case .data(_, let value): value.base64EncodedString()
        case .array(let values): values.compactMap(sendable)
        case .object(let object): object.compactMapValues(sendable)
        }
    }
}

enum ConnectorError: LocalizedError {
    case applicationNotInstalled(String)
    case serverUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .applicationNotInstalled(let name):
            String(localized: "\(name) is not installed on this Mac.")
        case .serverUnavailable(let name):
            String(localized: "\(name) is not accepting connections. Update \(name) and allow connections from other apps in its settings.")
        }
    }
}
