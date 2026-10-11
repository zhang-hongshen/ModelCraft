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

    static let modelIDs: Set<String> = [
        StableDiffusionConfiguration.presetSDXLTurbo.id,
        LTXVideoConfiguration.ltxv2BDistilled.id,
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
    /// is added in project chats, which is fixed for the life of a chat.
    static func allToolSchema(for chat: Chat?) -> [ToolSpec] {
        var tools = allTools.map(\.schema)
        if let projectID = chat?.project?.persistentModelID {
            tools.append(SearchTool.searchProject(projectID: projectID).schema)
        }
        return tools
    }
}
