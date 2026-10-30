//
//  ToolDefinitions.swift
//  ModelCraft
//
//  Created by Hongshen on 25/2/26.
//

import Foundation
import MLXLMCommon
import Tokenizers

enum ToolDefinition {

    /// Repositories downloaded for media tools, which live in `HubApi.system`.
    static let modelIDs: Set<String> = [
        StableDiffusionConfiguration.presetSDXLTurbo.id,
        LTXVideoConfiguration.ltxv2BDistilled.id,
        LTXVideoConfiguration.tokenizerRepositoryID,
        H3Configuration.presetH3BaseFL2VA.id,
        MusicGenConfiguration.small.id,
        MusicGenConfiguration.small.audioEncoderParameters.id,
        MusicGenConfiguration.small.textEncoderParameters.id,
    ]

    /// Tools offered on every request.
    static var coreTools: [any ToolProtocol] {
        [
            UserInputTool.allTools,
            FileTool.allTools,
            CommandTool.allTools,
            SkillTool.allTools,
            [WebTool.webFetch],
        ].flatMap { $0 }
    }

    /// Tools that, when tools load on demand, are offered only after `search_tools` finds them.
    static var deferredTools: [ToolSpec] {
        [
            AppTool.allTools,
            ComputerUseTool.allTools,
            ScreenControlTool.allTools,
            ImageTool.allTools,
            VideoTool.allTools,
            AudioTool.allTools,
            SearchTool.allTools,
            ScheduleTool.allTools,
            ModelCraftTool.allTools,
        ].flatMap { $0 }.map(\.schema)
    }

    /// When tools load on demand, a chat starts with the core tools, the installed connectors'
    /// tools and `search_tools`, and every tool a search finds is appended in the order it was
    /// found, so the list only grows and earlier requests stay a prefix. Otherwise every tool is
    /// offered on every request. Project search is added in project chats, which is fixed for the
    /// life of a chat; connector tools change only when the user installs or uninstalls a
    /// connector, and are never deferred because the user installed them to be used.
    static func allToolSchema(for chat: Chat?) -> [ToolSpec] {
        var tools = coreTools.map(\.schema)
        if let projectID = chat?.project?.persistentModelID {
            tools.append(SearchTool.searchProject(projectID: projectID).schema)
        }
        tools += Connector.allCases.flatMap(ConnectorTool.schemas(of:))
        if UserDefaults.standard.value(
            forKey: UserDefaults.loadToolsWhenNeeded,
            default: UserDefaultSettings.loadToolsWhenNeeded) {
            tools.append(searchTools.schema)
            let deferredTools = deferredTools
            tools += foundToolNames(in: chat).compactMap { name in
                deferredTools.first { toolName(of: $0) == name }
            }
        } else {
            tools += deferredTools
        }
        return tools
    }

    /// Names of the tools found by successful `search_tools` calls in the chat, in the order
    /// they were found.
    static func foundToolNames(in chat: Chat?) -> [String] {
        guard let chat else { return [] }
        var names: [String] = []
        for message in chat.conversation
        where message.role == .tool && message.status == .generated
            && message.toolCall?.function.name == ToolNames.searchTools {
            guard let output = try? JSONDecoder().decode(
                SearchToolsOutput.self, from: Data(message.content.utf8)) else { continue }
            for name in output.tools where !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    static var searchTools: Tool<SearchToolsInput, SearchToolsOutput> {
        let names = deferredTools.compactMap(toolName(of:)).joined(separator: ", ")
        return Tool<SearchToolsInput, SearchToolsOutput>(
            name: ToolNames.searchTools,
            description:
            """
                Search for tools that are not loaded yet by keyword, and load the matches. A tool listed below can be called only after a search has returned it; a returned tool stays available for the rest of the conversation. Returns the names of the matching tools, best match first; the full schemas of the returned tools are available from the next step.
                Tools not loaded yet: \(names)
            """,
            parameters: [
                .required("query", type: .string, description: "Keywords describing the capability needed, such as `calendar event` or `click button`, or one or more exact tool names separated by spaces."),
                .optional("max_results", type: .int, description: "The maximum number of tools to return. Defaults to 5."),
            ]
        ) { input in
            let terms = input.query.lowercased()
                .split { !$0.isLetter && !$0.isNumber && $0 != "_" }
                .map(String.init)
                .filter { $0.count > 1 }
            let ranked = deferredTools.compactMap { schema -> (ToolSpec, Int)? in
                let score = searchScore(of: schema, terms: terms)
                return score > 0 ? (schema, score) : nil
            }
            .sorted { $0.1 > $1.1 }
            .prefix(max(input.maxResults ?? 5, 1))
            return SearchToolsOutput(tools: ranked.compactMap { toolName(of: $0.0) })
        }
    }

    static func toolName(of schema: ToolSpec) -> String? {
        (schema["function"] as? [String: any Sendable])?["name"] as? String
    }

    /// An exact tool name outranks a match within a name, which outranks a description match.
    private static func searchScore(of schema: ToolSpec, terms: [String]) -> Int {
        guard let name = toolName(of: schema)?.lowercased() else { return 0 }
        let function = schema["function"] as? [String: any Sendable]
        let description = (function?["description"] as? String)?.lowercased() ?? ""
        let nameWords = Set(name.split(separator: "_").map(String.init))
        return terms.reduce(0) { score, term in
            if term == name { return score + 100 }
            if nameWords.contains(term) { return score + 3 }
            if name.contains(term) { return score + 2 }
            return description.contains(term) ? score + 1 : score
        }
    }
}

struct SearchToolsInput: Codable {
    let query: String
    let maxResults: Int?

    enum CodingKeys: String, CodingKey {
        case query
        case maxResults = "max_results"
    }
}

struct SearchToolsOutput: Codable {
    /// Names of the matching tools; the executor offers their full schemas in the tool list.
    let tools: [String]
}
