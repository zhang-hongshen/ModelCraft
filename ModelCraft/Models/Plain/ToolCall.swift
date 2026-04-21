//
//  ToolCall.swift
//  ModelCraft
//
//  Created by Hongshen on 21/1/26.
//

import Foundation
import MLXLMCommon
import SwiftUI


struct ToolNames {
    static let readFromFile = "read_from_file"
    static let writeToFile = "write_to_file"
    static let executeCommand = "execute_command"
    static let searchMap = "search_map"
    static let searchRelevantDocuments = "search_relevant_documents"
    static let captureScreen = "capture_screen"
    static let move = "move"
    static let click = "click"
    static let drag = "drag"
    static let scroll = "scroll"
    static let activateSkill = "activate_skill"
    static let textToImage = "text_to_image"
    static let textToVideo = "text_to_video"
}

extension ToolCall {
    
    func localizedDescription(toolCallStatus: ToolCallStatus) -> LocalizedStringKey {
        let arguments = function.arguments
        switch function.name {
        case ToolNames.readFromFile:
            let path = arguments["path"]?.stringValue ?? "Unknown"
            switch toolCallStatus {
            case .running: 
                return "Reading \(String(describing: path))"
            case .completed:
                return "Read \(String(describing: path))"
            case .failed:
                return "Failed to read \(String(describing: path))"
            }
        case ToolNames.writeToFile:
            let path = arguments["path"]?.stringValue ?? "Unknown"
            switch toolCallStatus {
            case .running: 
                return "Writing \(String(describing: path))"
            case .completed:
                return "Wrote \(String(describing: path))"
            case .failed:
                return "Failed to write \(String(describing: path))"
            }
        case ToolNames.executeCommand:
            let command = arguments["command"]?.stringValue ?? "None"
            switch toolCallStatus {
            case .running:
                return "Running \(String(describing: command))"
            case .completed:
                return "Ran \(String(describing: command))"
            case .failed:
                return "Command failed: \(String(describing: command))"
            }
        case ToolNames.searchMap:
            let query = arguments["query"]?.stringValue ?? ""
            switch toolCallStatus {
            case .running:
                return "Searching map for \(String(describing: query))"
            case .completed:
                return "Searched map for \(String(describing: query))"
            case .failed:
                return "Map search failed"
            }
        case ToolNames.searchRelevantDocuments:
            let query = arguments["query"]?.stringValue ?? ""
            switch toolCallStatus {
            case .running:
                return "Searching documents for \(String(describing: query))"
            case .completed:
                return "Searched documents for \(String(describing: query))"
            case .failed:
                return "Document search failed"
            }
        case ToolNames.click:
            let x = arguments["x"]?.doubleValue ?? 0
            let y = arguments["y"]?.doubleValue ?? 0
            switch toolCallStatus {
            case .running:
                return "Clicking (\(x), \(y))"
            case .completed:
                return "Clicked (\(x), \(y))"
            case .failed:
                return "Click failed at (\(x), \(y))"
            }
        case ToolNames.move:
            let x = arguments["x"]?.doubleValue ?? 0
            let y = arguments["y"]?.doubleValue ?? 0
            switch toolCallStatus {
            case .running:
                return "Moving pointer to (\(x), \(y))"
            case .completed:
                return "Moved to (\(x), \(y))"
            case .failed:
                return "Move failed"
            }
        case ToolNames.captureScreen:
            switch toolCallStatus {
            case .running: 
                return "Taking screenshot"
            case .completed: 
                return "Screenshot captured"
            case .failed: 
                return "Screenshot failed"
            }
        case ToolNames.textToImage:
            switch toolCallStatus {
            case .running: 
                return "Creating image"
            case .completed: 
                return "Image created"
            case .failed: 
                return "Image creation failed"
            }
        case ToolNames.textToVideo:
            switch toolCallStatus {
            case .running: 
                return "Creating video"
            case .completed:
                return "Video created"
            case .failed:
                return "Video creation failed"
            }
        case ToolNames.activateSkill:
            let name = arguments["name"]?.stringValue ?? ""
            switch toolCallStatus {
            case .running:
                return "Activating skill \(String(describing: name))"
            case .completed:
                return "Activated skill \(String(describing: name))"
            case .failed:
                return "Skill activation failed"
            }
        default:
            return "Unknown Tool Call"
        }
    }
    
    var icon: String {
        switch function.name {
        case ToolNames.readFromFile: "square.and.pencil"
        case ToolNames.writeToFile: "square.and.pencil"
        case ToolNames.executeCommand : "apple.terminal"
        case ToolNames.searchMap: "map"
        case ToolNames.searchRelevantDocuments: "magnifyingglass"
        case ToolNames.click, ToolNames.move: "pointer.arrow"
        case ToolNames.captureScreen: "camera"
        case ToolNames.textToImage: "photo"
        case ToolNames.textToVideo: "video"
        default: "error"
        }
    }
}
