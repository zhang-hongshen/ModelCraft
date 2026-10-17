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
    
    static var allTools: [any ToolProtocol] {
        [
            UserInputTool.allTools,
            FileTool.allTools,
            SearchTool.allTools,
            CommandTool.allTools,
            ImageTool.allTools,
            VideoTool.allTools,
            AudioTool.allTools,
            ComputerUseTool.allTools,
            ScreenControlTool.allTools,
            SkillTool.allTools,
            AppTool.allTools,
            [WebTool.webFetch],
        ].flatMap { $0 }
    }

    /// The same tools on every request, so the prompt prefix stays reusable. Project search
    /// is added in project chats, which is fixed for the life of a chat; connector tools change
    /// only when the user installs or uninstalls a connector.
    static func allToolSchema(for chat: Chat?) -> [ToolSpec] {
        var tools = allTools.map(\.schema) + ConnectorTool.schemas
        if let projectID = chat?.project?.persistentModelID {
            tools.append(SearchTool.searchProject(projectID: projectID).schema)
        }
        return tools
    }
}
