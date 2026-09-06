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
            SkillTool.allTools
        ].flatMap { $0 }
    }
    
    @MainActor
    static var allToolSchema: [ToolSpec] {
        var tools = allTools.map { $0.schema }
        if NetworkMonitor.shared.isConnected {
            tools.append(WebTool.webFetch.schema)
        }
        return tools
    }
    
}
