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
                toolCallResult.content.append(.text(TextContent(text: result.toolResult)))
                message.content = result.toolResult
            case ToolNames.searchMap:
                let result = try await toolCall.execute(with: SearchTool.searchMap)
                toolCallResult.content.append(.text(TextContent(text: result.toolResult)))
                message.content = result.toolResult
            case ToolNames.textToImage:
                let result = try await toolCall.execute(with: ImageTool.textToImage)
                toolCallResult.content.append(
                    .resourceLink(ResourceLink(name: "", title: "", url: result.imageURL, mimeType: result.mimeType)))
                message.images.append(.url(result.imageURL))
            case ToolNames.textToVideo:
                let result = try await toolCall.execute(with: VideoTool.textToVideo)
                toolCallResult.content.append(
                    .resourceLink(ResourceLink(name: "", title: "", url: result.videoURL, mimeType: result.mimeType)))
                message.videos.append(.url(result.videoURL))
            case ToolNames.textToAudio:
                let result = try await toolCall.execute(with: AudioTool.textToAudio)
                toolCallResult.content.append(
                    .resourceLink(ResourceLink(name: "", title: "", url: result.audioURL, mimeType: result.mimeType)))
                message.videos.append(.url(result.audioURL))
            case ToolNames.activateSkill:
                let result = try await toolCall.execute(with: SkillTool.activateSkill)
                toolCallResult.content.append(.text(TextContent(text: result.content)))
                message.content = result.toolResult
            case ToolNames.captureFullScreen:
                if let result = try await toolCall.execute(with: ScreenControlTool.captureFullScreen) {
                    toolCallResult.content.append(.text(TextContent(
                        text: "Captured all displays at \(Int(result.size.width))x\(Int(result.size.height)) points."
                    )))
                    toolCallResult.content.append(.image(ImageContent(data: result.imageData.base64EncodedString(), mimeType: result.mimeType)))
                    if let ciImage = CIImage(data: result.imageData){
                        message.images.append(.ciImage(ciImage))
                    }
                } else {
                    let errorDescription = "Failed to capture the full screen."
                    toolCallResult.isError = true
                    toolCallResult.content.append(.text(TextContent(text: errorDescription)))
                    message.content = errorDescription
                }
            case ToolNames.captureAppWindow:
                let screenshots = try await toolCall.execute(with: ScreenControlTool.captureAppWindow)
                if screenshots.isEmpty {
                    let resultDescription = "No application windows were captured."
                    toolCallResult.isError = true
                    toolCallResult.content.append(.text(TextContent(text: resultDescription)))
                    message.content = resultDescription
                } else {
                    for screenshot in screenshots {
                        let frame = screenshot.windowFrame
                        toolCallResult.content.append(.text(TextContent(
                            text: "Window \(screenshot.windowID): x=\(Int(frame.minX)), y=\(Int(frame.minY)), width=\(Int(frame.width)), height=\(Int(frame.height))."
                        )))
                        toolCallResult.content.append(.image(ImageContent(data: screenshot.imageData.base64EncodedString(), mimeType: screenshot.mimeType)))
                        if let ciImage = CIImage(data: screenshot.imageData){
                            message.images.append(.ciImage(ciImage))
                        }
                    }
                }
            case ToolNames.click:
                let result = try await toolCall.execute(with: ScreenControlTool.click)
                toolCallResult.content.append(.text(TextContent(text: result.toolResult)))
                message.content = result.toolResult
            case ToolNames.move:
                let result = try await toolCall.execute(with: ScreenControlTool.move)
                toolCallResult.content.append(.text(TextContent(text: result.toolResult)))
                message.content = result.toolResult
            case ToolNames.drag:
                let result = try await toolCall.execute(with: ScreenControlTool.drag)
                toolCallResult.content.append(.text(TextContent(text: result.toolResult)))
                message.content = result.toolResult
            case ToolNames.scroll:
                let result = try await toolCall.execute(with: ScreenControlTool.scroll)
                toolCallResult.content.append(.text(TextContent(text: result.toolResult)))
                message.content = result.toolResult
            case ToolNames.listRunningApps:
                let result = try await toolCall.execute(with: ComputerUseTool.listRunningApplication)
                toolCallResult.content.append(.text(TextContent(text: result.toolResult)))
                message.content = result.toolResult
            case ToolNames.getUIHierarchy:
                let result = try await toolCall.execute(with: ComputerUseTool.getUIHierarchy)
                toolCallResult.content.append(.text(TextContent(text: result.toolResult)))
                message.content = result.toolResult
            case ToolNames.clickElement:
                let result = try await toolCall.execute(with: ComputerUseTool.clickElement)
                toolCallResult.content.append(.text(TextContent(text: result.toolResult)))
                message.content = result.toolResult
            case ToolNames.typeText:
                let result = try await toolCall.execute(with: ComputerUseTool.typeText)
                toolCallResult.content.append(.text(TextContent(text: result.toolResult)))
                message.content = result.toolResult
            case ToolNames.pressKey:
                let result = try await toolCall.execute(with: ComputerUseTool.pressKey)
                toolCallResult.content.append(.text(TextContent(text: result.toolResult)))
                message.content = result.toolResult
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
