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
    // MARK: Decision Tool
    static let requestDecision = "request_decision"

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
    static let listRunningApps = "list_running_application"
    static let getUIHierarchy = "get_ui_hierarchy"
    static let clickElement = "click_element"
    static let typeText = "type_text"
    static let pressKey = "press_key"
}




extension ToolCall {

    var fileDisplayName: String? {
        guard let path = function.arguments["path"]?.stringValue else {
            return nil
        }
        return (path as NSString).lastPathComponent
    }

    func compactDescription(_ status: ToolCallStatus) -> String {
        guard function.name == ToolNames.executeCommand else {
            return localizedDescription(status)
        }

        switch status {
        case .running:
            return String(localized: "Running a command")
        case .completed:
            return String(localized: "Ran a command")
        case .failed:
            return String(localized: "Command failed")
        }
    }
    
    func localizedDescription(_ status: ToolCallStatus) -> String {
        let arguments = function.arguments
        switch function.name {
        case ToolNames.requestDecision:
            switch status {
            case .running:
                return String(localized: "Waiting for a decision")
            case .completed:
                return String(localized: "Decision received")
            case .failed:
                return String(localized: "Decision cancelled")
            }
        case ToolNames.readFromFile:
            let fileName = fileDisplayName ?? String(localized: "Unknown")
            switch status {
            case .running:
                return String(localized: "Reading \(fileName)")
            case .completed:
                return String(localized: "Read \(fileName)")
            case .failed:
                return String(localized: "Failed to read \(fileName)")
            }
        case ToolNames.writeToFile:
            let fileName = fileDisplayName ?? String(localized: "Unknown")
            switch status {
            case .running:
                return String(localized: "Writing into \(fileName)")
            case .completed:
                return String(localized: "Wrote into \(fileName)")
            case .failed:
                return String(localized: "Failed to write into \(fileName)")
            }
        case ToolNames.executeCommand:
            return compactDescription(status)
        case ToolNames.searchMap:
            let query = arguments["query"]?.stringValue ?? ""
            switch status {
            case .running:
                return String(localized: "Searching map for \(query)")
            case .completed:
                return String(localized: "Searched map for \(query)")
            case .failed:
                return String(localized: "Map search failed")
            }
        case ToolNames.searchRelevantDocuments:
            let query = arguments["query"]?.stringValue ?? ""
            switch status {
            case .running:
                return String(localized: "Searching documents for \(query)")
            case .completed:
                return String(localized: "Searched documents for \(query)")
            case .failed:
                return String(localized: "Document search failed")
            }
        case ToolNames.click:
            let x = arguments["x"]?.doubleValue ?? 0
            let y = arguments["y"]?.doubleValue ?? 0
            switch status {
            case .running:
                return String(localized: "Clicking (\(x), \(y))")
            case .completed:
                return String(localized: "Clicked (\(x), \(y))")
            case .failed:
                return String(localized: "Click failed at (\(x), \(y))")
            }
        case ToolNames.move:
            let x = arguments["x"]?.doubleValue ?? 0
            let y = arguments["y"]?.doubleValue ?? 0
            switch status {
            case .running:
                return String(localized: "Moving pointer to (\(x), \(y))")
            case .completed:
                return String(localized: "Moved to (\(x), \(y))")
            case .failed:
                return String(localized: "Move failed")
            }
        case ToolNames.captureFullScreen:
            switch status {
            case .running:
                return String(localized: "Taking full screenshot")
            case .completed:
                return String(localized: "Full screenshot captured")
            case .failed:
                return String(localized: "Full screenshot failed")
            }
        case ToolNames.captureAppWindow:
            switch status {
            case .running:
                return String(localized: "Capturing application windows")
            case .completed:
                return String(localized: "Captured application windows")
            case .failed:
                return String(localized: "Application window capture failed")
            }
        case ToolNames.drag:
            switch status {
            case .running:
                return String(localized: "Dragging pointer")
            case .completed:
                return String(localized: "Dragged pointer")
            case .failed:
                return String(localized: "Drag failed")
            }
        case ToolNames.scroll:
            switch status {
            case .running:
                return String(localized: "Scrolling")
            case .completed:
                return String(localized: "Scrolled")
            case .failed:
                return String(localized: "Scroll failed")
            }
        case ToolNames.textToImage:
            switch status {
            case .running:
                return String(localized: "Creating image")
            case .completed: 
                return String(localized: "Image created")
            case .failed: 
                return String(localized: "Image creation failed")
            }
        case ToolNames.textToVideo:
            switch status {
            case .running: 
                return String(localized: "Creating video")
            case .completed:
                return String(localized: "Video created")
            case .failed:
                return String(localized: "Video creation failed")
            }
        case ToolNames.textToAudio:
            switch status {
            case .running:
                return String(localized: "Creating audio")
            case .completed:
                return String(localized: "Audio created")
            case .failed:
                return String(localized: "Audio creation failed")
            }
        case ToolNames.activateSkill:
            let name = arguments["name"]?.stringValue ?? ""
            switch status {
            case .running:
                return String(localized: "Activating skill \(name)")
            case .completed:
                return String(localized: "Activated skill \(name)")
            case .failed:
                return String(localized: "Skill activation failed")
            }
        case ToolNames.listRunningApps:
            switch status {
            case .running:
                return String(localized: "Listing running applications")
            case .completed:
                return String(localized: "Listed running applications")
            case .failed:
                return String(localized: "Failed to list running applications")
            }
        case ToolNames.getUIHierarchy:
            switch status {
            case .running:
                return String(localized: "Inspecting UI hierarchy")
            case .completed:
                return String(localized: "Inspected UI hierarchy")
            case .failed:
                return String(localized: "UI hierarchy inspection failed")
            }
        case ToolNames.clickElement:
            switch status {
            case .running:
                return String(localized: "Clicking an element")
            case .completed:
                return String(localized: "Clicked an element")
            case .failed:
                return String(localized: "Element click failed")
            }
        case ToolNames.typeText:
            switch status {
            case .running:
                return String(localized: "Typing text")
            case .completed:
                return String(localized: "Typed text")
            case .failed:
                return String(localized: "Text input failed")
            }
        case ToolNames.pressKey:
            switch status {
            case .running:
                return String(localized: "Pressing a key")
            case .completed:
                return String(localized: "Pressed a key")
            case .failed:
                return String(localized: "Key press failed")
            }
        default:
            return String(localized: "Unknown Tool Call")
        }
    }
    
    var icon: String {
        switch function.name {
        case ToolNames.requestDecision: "questionmark.bubble"
        case ToolNames.readFromFile: "square.and.pencil"
        case ToolNames.writeToFile: "square.and.pencil"
        case ToolNames.executeCommand : "apple.terminal"
        case ToolNames.searchMap: "map"
        case ToolNames.searchRelevantDocuments: "magnifyingglass"
        case ToolNames.textToImage: "photo"
        case ToolNames.textToVideo: "video"
        case ToolNames.textToAudio: "waveform"
        case ToolNames.activateSkill: "sparkles"
        case ToolNames.listRunningApps: "app.badge"
        case ToolNames.getUIHierarchy: "list.bullet.indent"
        case ToolNames.click, ToolNames.clickElement, ToolNames.move, ToolNames.drag: "pointer.arrow"
        case ToolNames.scroll: "arrow.up.and.down"
        case ToolNames.captureFullScreen: "display.2"
        case ToolNames.captureAppWindow: "macwindow"
        case ToolNames.typeText, ToolNames.pressKey: "keyboard"
        default: "exclamationmark.triangle"
        }
    }
}
