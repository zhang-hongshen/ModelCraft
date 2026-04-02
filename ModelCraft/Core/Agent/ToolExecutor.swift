//
//  ToolExecutor.swift
//  ModelCraft
//
//  Created by Hongshen on 10/3/26.
//

import CoreImage

import MLXLMCommon

class ToolExecutor {
    
    static let shared = ToolExecutor()
    
    func dispath(_ toolCall: ToolCall) async throws -> (String, MLXLMCommon.Chat.Message) {
        var toolCallResult = ""
        var message = MLXLMCommon.Chat.Message(role: .tool, content: "")
        switch toolCall.function.name {
        case ToolNames.readFromFile:
            let result = try await toolCall.execute(with: FileTool.readFromFile)
            toolCallResult = result.toolResult
            message.content = result.toolResult
        case ToolNames.writeToFile:
            let result = try await toolCall.execute(with: FileTool.writeToFile)
            toolCallResult = result.toolResult
            message.content = result.toolResult
        case ToolNames.searchMap:
            let result = try await toolCall.execute(with: SearchTool.searchMap)
            toolCallResult = result.toolResult
            message.content = result.toolResult
        case ToolNames.captureScreen:
            if let result = try await toolCall.execute(with: ScreenControlTool.captureScreen) {
                toolCallResult = result.imageData.base64EncodedString()
                if let ciImage = CIImage(data: result.imageData){
                    message.images.append(.ciImage(ciImage))
                }
            }
        case ToolNames.click:
            let result = try await toolCall.execute(with: ScreenControlTool.click)
            toolCallResult = result.toolResult
            message.content = result.toolResult
        case ToolNames.move:
            let result = try await toolCall.execute(with: ScreenControlTool.move)
            toolCallResult = result.toolResult
            message.content = result.toolResult
        case ToolNames.activateSkill:
            let result = try await toolCall.execute(with: SkillTool.activateSkill)
            toolCallResult = result.toolResult
            message.content = result.toolResult
        #if os(macOS)
        case ToolNames.executeCommand:
            let result = try await toolCall.execute(with: CommandTool.executeCommand)
            toolCallResult = result.toolResult
            message.content = result.toolResult
        #endif
        default:
            message.content = "Unknown tool: \(toolCall.function.name)"
        }
        print("ToolCallResult \(toolCallResult)")
        return (toolCallResult, message)
    }
}
