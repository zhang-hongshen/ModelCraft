//
//  ToolDefinitions.swift
//  ModelCraft
//
//  Created by Hongshen on 25/2/26.
//

import Foundation

struct ToolDefinition {
    
    static var allTools = FileTool.allTools +
        SearchTool.allTools +
        CommandTool.allTools +
        ScreenControlTool.allTools +
        SkillTool.allTools
}
