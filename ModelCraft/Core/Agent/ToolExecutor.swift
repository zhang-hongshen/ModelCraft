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
        projectID: PersistentIdentifier?,
        modelID: String
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
                // The model gets the file text as is: JSON escaping (`\/`, `\"`, `\n`) gets
                // copied into `apply_patch` lines, which then no longer match the file.
                reply(try await toolCall.execute(with: FileTool.readFile).content)
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
            case ToolNames.searchTools:
                reply(try await toolCall.execute(with: ToolDefinition.searchTools).toolResult)
            case ToolNames.appScreenshot:
                let result = try await toolCall.execute(with: ScreenControlTool.appScreenshot)
                reply(result.summary)
                toolCallResult.content.append(
                    .resourceLink(ResourceLink(name: "", title: "", url: result.imageURL, mimeType: result.mimeType)))
            case ToolNames.appZoom:
                let result = try await toolCall.execute(with: ScreenControlTool.appZoom)
                reply(result.summary)
                toolCallResult.content.append(
                    .resourceLink(ResourceLink(name: "", title: "", url: result.imageURL, mimeType: result.mimeType)))
            case ToolNames.listApps:
                reply(try await toolCall.execute(with: ComputerUseTool.listApps).toolResult)
            case ToolNames.openApp:
                reply(try await toolCall.execute(with: ComputerUseTool.openApp).toolResult)
            case ToolNames.appFind:
                // One element per line reads better than a JSON array of escaped strings.
                reply(try await toolCall.execute(with: ComputerUseTool.appFind).joined(separator: "\n"))
            case ToolNames.appClick:
                reply(try await toolCall.execute(with: ComputerUseTool.appClick).result)
            case ToolNames.appType:
                reply(try await toolCall.execute(with: ComputerUseTool.appType).result)
            case ToolNames.appKey:
                reply(try await toolCall.execute(with: ComputerUseTool.appKey).result)
            case ToolNames.appScroll:
                reply(try await toolCall.execute(with: ComputerUseTool.appScroll).result)
            case ToolNames.appDrag:
                reply(try await toolCall.execute(with: ComputerUseTool.appDrag).result)
            case ToolNames.appMenu:
                reply(try await toolCall.execute(with: ComputerUseTool.appMenu).result)
            case ToolNames.searchNotes:
                reply(try await toolCall.execute(with: AppTool.searchNotes).toolResult)
            case ToolNames.readNote:
                reply(try await toolCall.execute(with: AppTool.readNote).toolResult)
            case ToolNames.createNote:
                reply(try await toolCall.execute(with: AppTool.createNote).toolResult)
            case ToolNames.updateNote:
                reply(try await toolCall.execute(with: AppTool.updateNote).toolResult)
            case ToolNames.searchCalendar:
                reply(try await toolCall.execute(with: AppTool.searchCalendar).toolResult)
            case ToolNames.readCalendarEvent:
                reply(try await toolCall.execute(with: AppTool.readCalendarEvent).toolResult)
            case ToolNames.createCalendarEvent:
                reply(try await toolCall.execute(with: AppTool.createCalendarEvent).toolResult)
            case ToolNames.updateCalendarEvent:
                reply(try await toolCall.execute(with: AppTool.updateCalendarEvent).toolResult)
            case ToolNames.searchReminders:
                reply(try await toolCall.execute(with: AppTool.searchReminders).toolResult)
            case ToolNames.readReminder:
                reply(try await toolCall.execute(with: AppTool.readReminder).toolResult)
            case ToolNames.createReminder:
                reply(try await toolCall.execute(with: AppTool.createReminder).toolResult)
            case ToolNames.updateReminder:
                reply(try await toolCall.execute(with: AppTool.updateReminder).toolResult)
            case ToolNames.searchMail:
                reply(try await toolCall.execute(with: AppTool.searchMail).toolResult)
            case ToolNames.readMail:
                reply(try await toolCall.execute(with: AppTool.readMail).toolResult)
            case ToolNames.createMailDraft:
                reply(try await toolCall.execute(with: AppTool.createMailDraft).toolResult)
            case ToolNames.runAppleScript:
                reply(try await toolCall.execute(with: AppTool.runAppleScript).toolResult)
            case ToolNames.executeCommand:
                reply(try await toolCall.execute(with: CommandTool.executeCommand).toolResult)
            case ToolNames.createSchedule:
                reply(try await toolCall.execute(with: ScheduleTool.createSchedule(
                    projectID: projectID, modelID: modelID)).toolResult)
            case ToolNames.listSchedules:
                reply(try await toolCall.execute(with: ScheduleTool.listSchedules).toolResult)
            case ToolNames.updateSchedule:
                reply(try await toolCall.execute(with: ScheduleTool.updateSchedule).toolResult)
            case ToolNames.deleteSchedule:
                reply(try await toolCall.execute(with: ScheduleTool.deleteSchedule).toolResult)
            case ToolNames.listWorkdays:
                reply(try await toolCall.execute(with: ScheduleTool.listWorkdays).toolResult)
            case ToolNames.setWorkday:
                reply(try await toolCall.execute(with: ScheduleTool.setWorkday).toolResult)
            case ToolNames.readSettings:
                reply(try await toolCall.execute(with: ModelCraftTool.readSettings).toolResult)
            case ToolNames.updateSettings:
                reply(try await toolCall.execute(with: ModelCraftTool.updateSettings).toolResult)
            case ToolNames.openPage:
                reply(try await toolCall.execute(with: ModelCraftTool.openPage).toolResult)
            case ToolNames.listProjects:
                reply(try await toolCall.execute(with: ModelCraftTool.listProjects).toolResult)
            case ToolNames.createProject:
                reply(try await toolCall.execute(with: ModelCraftTool.createProject).toolResult)
            case ToolNames.updateProject:
                reply(try await toolCall.execute(with: ModelCraftTool.updateProject).toolResult)
            default:
                if let connector = Connector(toolName: toolCall.function.name) {
                    (toolCallResult, message) = try await ConnectorTool.call(toolCall, connector: connector)
                } else {
                    toolCallResult.isError = true
                    reply("Unknown tool: \(toolCall.function.name)")
                }
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
