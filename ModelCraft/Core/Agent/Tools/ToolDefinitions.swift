//
//  ToolDefinitions.swift
//  ModelCraft
//
//  Created by Hongshen on 25/2/26.
//

import Foundation
import MLXLMCommon
import Tokenizers

struct ToolDefinition {
    
    static var allTools: [any ToolProtocol] = [
        FileTool.allTools,
        SearchTool.allTools,
        CommandTool.allTools,
        ImageTool.allTools,
        VideoTool.allTools,
        AudioTool.allTools,
        ComputerUseTool.allTools,
        ScreenControlTool.allTools,
        SkillTool.allTools
    ].flatMap{ $0 }
    
    static var allToolSchema = allTools.map { $0.schema }
    
}

