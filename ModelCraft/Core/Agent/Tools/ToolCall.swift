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
    // MARK: File Tool
    static let readFromFile = "read_from_file"
    static let writeToFile = "write_to_file"

    // MARK: Command Tool
    static let executeCommand = "execute_command"

    // MARK: Search Tool
    static let searchMap = "search_map"
    static let searchRelevantDocuments = "search_relevant_documents"

    // MARK: Screen Control Tool
    static let captureFullScreen = "capture_full_screen"
    static let captureAppWindow = "capture_app_window"
    static let move = "move"
    static let click = "click"
    static let drag = "drag"
    static let scroll = "scroll"

    // MARK: Skill Tool
    static let activateSkill = "activate_skill"

    // MARK: Image Tool
    static let textToImage = "text_to_image"

    // MARK: Video Tool
    static let textToVideo = "text_to_video"

    // MARK: Audio Tool
    static let textToAudio = "text_to_audio"

    // MARK: Computer Use Tool
    static let listRunningApps = "list_running_apps"
    static let getUIHierarchy = "get_ui_hierarchy"
    static let clickElement = "click_element"
    static let typeText = "type_text"
    static let pressKey = "press_key"
}




extension ToolCall {
    
    func localizedDescription(_ status: ToolCallStatus) -> String {
        let arguments = function.arguments
        switch function.name {
        case ToolNames.readFromFile:
            let path = arguments["path"]?.stringValue ?? "Unknown"
            switch status {
            case .running:
                return String(format: String(localized: "Reading %@"), path)
            case .completed:
                return String(format: String(localized: "Read %@"), path)
            case .failed:
                return String(format: String(localized: "Failed to read %@"), path)
            }
        case ToolNames.writeToFile:
            let path = arguments["path"]?.stringValue ?? "Unknown"
            switch status {
            case .running:
                return String(format: String(localized: "Writing %@"), path)
            case .completed:
                return String(format: String(localized: "Wrote %@"), path)
            case .failed:
                return String(format: String(localized: "Failed to write %@"), path)
            }
        case ToolNames.executeCommand:
            let command = arguments["command"]?.stringValue ?? "None"
            switch status {
            case .running:
                return String(format: String(localized: "Running %@"), command)
            case .completed:
                return String(format: String(localized: "Ran %@"), command)
            case .failed:
                return String(format: String(localized: "Command failed: %@"), command)
            }
        case ToolNames.searchMap:
            let query = arguments["query"]?.stringValue ?? ""
            switch status {
            case .running:
                return "Searching map for \(String(describing: query))"
            case .completed:
                return "Searched map for \(String(describing: query))"
            case .failed:
                return "Map search failed"
            }
        case ToolNames.searchRelevantDocuments:
            let query = arguments["query"]?.stringValue ?? ""
            switch status {
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
            switch status {
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
            switch status {
            case .running:
                return "Moving pointer to (\(x), \(y))"
            case .completed:
                return "Moved to (\(x), \(y))"
            case .failed:
                return "Move failed"
            }
        case ToolNames.captureFullScreen:
            switch status {
            case .running:
                return "Taking full screenshot"
            case .completed:
                return "Full screenshot captured"
            case .failed:
                return "Full screenshot failed"
            }
        case ToolNames.textToImage:
            switch status {
            case .running:
                return "Creating image"
            case .completed: 
                return "Image created"
            case .failed: 
                return "Image creation failed"
            }
        case ToolNames.textToVideo:
            switch status {
            case .running: 
                return "Creating video"
            case .completed:
                return "Video created"
            case .failed:
                return "Video creation failed"
            }
        case ToolNames.activateSkill:
            let name = arguments["name"]?.stringValue ?? ""
            switch status {
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
        case ToolNames.textToImage: "photo"
        case ToolNames.textToVideo: "video"
        case ToolNames.textToAudio: "waveform"
        case ToolNames.click, ToolNames.clickElement, ToolNames.move: "pointer.arrow"
        case ToolNames.captureFullScreen: "display.2"
        case ToolNames.captureAppWindow: "macwindow"
        case ToolNames.typeText, ToolNames.pressKey: "keyboard"
        default: "error"
        }
    }
}
