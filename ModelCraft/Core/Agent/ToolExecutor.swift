//
//  ToolExecutor.swift
//  ModelCraft
//
//  Created by Hongshen on 10/3/26.
//

import Foundation
import SwiftData

import MLXLMCommon

enum ToolExecutor {
    
    static func dispatch(
        _ toolCall: ToolCall,
        projectID: PersistentIdentifier?
    ) async throws -> (CallToolResult, MLXLMCommon.Chat.Message) {
        try Task.checkCancellation()
        
        var toolCallResult = CallToolResult()
        var message = MLXLMCommon.Chat.Message(role: .tool, content: "")

        func reply(_ text: String) {
            toolCallResult.content.append(.text(TextContent(text: text)))
            message.content = text
        }

        do  {
            switch toolCall.function.name {
            case ToolNames.readFile:
                let result = try await toolCall.execute(with: FileTool.readFile)
                toolCallResult.content.append(.text(TextContent(text: result.content)))
                message.content = result.toolResult
            case ToolNames.applyPatch:
                reply(try await toolCall.execute(with: FileTool.applyPatch).toolResult)
            case ToolNames.listDirectory:
                reply(try await toolCall.execute(with: FileTool.listDirectory).toolResult)
            case ToolNames.searchMap:
                reply(try await toolCall.execute(with: SearchTool.searchMap).toolResult)
            case ToolNames.searchProject:
                guard let projectID else {
                    throw ToolExecutorError.projectUnavailable
                }
                let result = try await toolCall.execute(
                    with: SearchTool.searchProject(projectID: projectID))
                toolCallResult.content.append(.text(TextContent(text: result.toolResult)))
                message.content = result.toolResult
            case ToolNames.webFetch:
                let result = try await toolCall.execute(with: WebTool.webFetch)
                let url = URL(string: result.url)!
                toolCallResult.content.append(.resourceLink(ResourceLink(
                    name: result.title ?? url.host ?? result.url,
                    title: result.title ?? url.host ?? result.url,
                    url: url
                )))
                message.content = result.toolResult
            case ToolNames.textToImage:
                let result = try await toolCall.execute(with: ImageTool.textToImage)
                toolCallResult.content.append(
                    .resourceLink(ResourceLink(name: "", title: "", url: result.imageURL, mimeType: result.mimeType)))
                message.content = result.toolResult
            case ToolNames.textToVideo:
                let result = try await toolCall.execute(with: VideoTool.textToVideo)
                toolCallResult.content.append(
                    .resourceLink(ResourceLink(name: "", title: "", url: result.videoURL, mimeType: result.mimeType)))
                message.content = result.toolResult
            case ToolNames.textToAudio:
                let result = try await toolCall.execute(with: AudioTool.textToAudio)
                toolCallResult.content.append(
                    .resourceLink(ResourceLink(name: "", title: "", url: result.audioURL, mimeType: result.mimeType)))
                message.content = result.toolResult
            case ToolNames.activateSkill:
                let result = try await toolCall.execute(with: SkillTool.activateSkill)
                toolCallResult.content.append(.text(TextContent(text: result.content)))
                message.content = result.toolResult
            case ToolNames.captureFullScreen:
                if let result = try await toolCall.execute(with: ScreenControlTool.captureFullScreen) {
                    let description = "Captured all displays at \(Int(result.size.width))x\(Int(result.size.height)) points."
                    toolCallResult.content.append(.text(TextContent(text: description)))
                    toolCallResult.content.append(.image(ImageContent(data: result.imageData.base64EncodedString(), mimeType: result.mimeType)))
                    message.content = description
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
                    var descriptions: [String] = []
                    for screenshot in screenshots {
                        let frame = screenshot.windowFrame
                        let description = "Window \(screenshot.windowID): x=\(Int(frame.minX)), y=\(Int(frame.minY)), width=\(Int(frame.width)), height=\(Int(frame.height))."
                        toolCallResult.content.append(.text(TextContent(text: description)))
                        toolCallResult.content.append(.image(ImageContent(data: screenshot.imageData.base64EncodedString(), mimeType: screenshot.mimeType)))
                        descriptions.append(description)
                    }
                    message.content = descriptions.joined(separator: "\n")
                }
            case ToolNames.click:
                reply(try await toolCall.execute(with: ScreenControlTool.click).toolResult)
            case ToolNames.move:
                reply(try await toolCall.execute(with: ScreenControlTool.move).toolResult)
            case ToolNames.drag:
                reply(try await toolCall.execute(with: ScreenControlTool.drag).toolResult)
            case ToolNames.scroll:
                reply(try await toolCall.execute(with: ScreenControlTool.scroll).toolResult)
            case ToolNames.listRunningApps:
                reply(try await toolCall.execute(with: ComputerUseTool.listRunningApplication).toolResult)
            case ToolNames.getUIHierarchy:
                reply(try await toolCall.execute(with: ComputerUseTool.getUIHierarchy).toolResult)
            case ToolNames.clickElement:
                reply(try await toolCall.execute(with: ComputerUseTool.clickElement).toolResult)
            case ToolNames.typeText:
                reply(try await toolCall.execute(with: ComputerUseTool.typeText).toolResult)
            case ToolNames.pressKey:
                reply(try await toolCall.execute(with: ComputerUseTool.pressKey).toolResult)
            case ToolNames.executeCommand:
                reply(try await toolCall.execute(with: CommandTool.executeCommand).toolResult)
            default:
                toolCallResult.isError = true
                reply("Unknown tool: \(toolCall.function.name)")
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            toolCallResult.isError = true
            reply(error.localizedDescription)
        }
        print("ToolCall result \(toolCallResult)")
        return (toolCallResult, message)
    }
}

private enum ToolExecutorError: LocalizedError {
    case projectUnavailable

    var errorDescription: String? {
        "The project is unavailable."
    }
}
