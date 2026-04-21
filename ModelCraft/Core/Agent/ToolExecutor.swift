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
    
    func dispath(_ toolCall: ToolCall) async throws -> (CallToolResult, MLXLMCommon.Chat.Message) {
        var toolCallResult = CallToolResult()
        var message = MLXLMCommon.Chat.Message(role: .tool, content: "")
        do  {
            switch toolCall.function.name {
            case ToolNames.readFromFile:
                let result = try await toolCall.execute(with: FileTool.readFromFile)
                toolCallResult.content.append(.text(TextContent(text: result.content)))
                message.content = result.toolResult
            case ToolNames.writeToFile:
                let result = try await toolCall.execute(with: FileTool.writeToFile)
                message.content = result.toolResult
            case ToolNames.searchMap:
                let result = try await toolCall.execute(with: SearchTool.searchMap)
                toolCallResult.content.append(.text(TextContent(text: result.toolResult)))
                message.content = result.toolResult
            case ToolNames.captureScreen:
                if let result = try await toolCall.execute(with: ScreenControlTool.captureScreen) {
                    toolCallResult.content.append(.image(ImageContent(data: result.imageData.base64EncodedString(), mimeType: result.mimeType)))
                    if let ciImage = CIImage(data: result.imageData){
                        message.images.append(.ciImage(ciImage))
                    }
                }
            case ToolNames.click:
                let result = try await toolCall.execute(with: ScreenControlTool.click)
                message.content = result.toolResult
            case ToolNames.move:
                let result = try await toolCall.execute(with: ScreenControlTool.move)
                message.content = result.toolResult
            case ToolNames.activateSkill:
                let result = try await toolCall.execute(with: SkillTool.activateSkill)
                toolCallResult.content.append(.text(TextContent(text: result.content)))
                message.content = result.toolResult
            case ToolNames.textToImage:
                let result = try await toolCall.execute(with: ImageTool.textToImage)
                toolCallResult.content.append(
                    .resourceLink(ResourceLink(name: "", title: "", uri: result.imageURL.absoluteString, mimeType: result.mimeType)))
                message.images.append(.url(result.imageURL))
            case ToolNames.textToVideo:
                let result = try await toolCall.execute(with: VideoTool.textToVideo)
                toolCallResult.content.append(
                    .resourceLink(ResourceLink(name: "", title: "", uri: result.videoURL.absoluteString, mimeType: result.mimeType)))
                message.videos.append(.url(result.videoURL))
            #if os(macOS)
            case ToolNames.executeCommand:
                let result = try await toolCall.execute(with: CommandTool.executeCommand)
                toolCallResult.content.append(.text(TextContent(text: result.toolResult)))
                message.content = result.toolResult
            #endif
            default:
                toolCallResult.isError = true
                let errorDescription = "Unknown tool: \(toolCall.function.name)"
                toolCallResult.content.append(.text(TextContent(text: errorDescription)))
                message.content = errorDescription
            }
        } catch {
            toolCallResult.isError = true
            toolCallResult.content.append(.text(TextContent(text: error.localizedDescription)))
            message.content = error.localizedDescription
        }
        print("ToolCall result \(toolCallResult)")
        return (toolCallResult, message)
    }
}
