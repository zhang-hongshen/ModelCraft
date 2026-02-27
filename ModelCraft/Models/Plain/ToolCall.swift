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
}

extension ToolCall {
    
    var localizedName: LocalizedStringKey {
        let arguments = function.arguments
        switch function.name {
        case ToolNames.readFromFile:
            let path = arguments["path"]?.stringValue ?? "Unknown"
            return "Reading from file \(String(describing: path))"
        case ToolNames.writeToFile:
            let path = arguments["path"]?.stringValue ?? "Unknown"
            return "Writing to file \(String(describing: path))"
        case ToolNames.executeCommand:
            let command = arguments["command"]?.stringValue ?? "None"
            return "Executing command \(String(describing: command))"
        case ToolNames.searchMap:
            let query = arguments["query"]?.stringValue ?? ""
            return "Searching for \(String(describing: query))"
        case ToolNames.searchRelevantDocuments:
            let query = arguments["query"]?.stringValue ?? ""
            return "Search for \(String(describing: query))"
        case ToolNames.click:
            let x = arguments["x"]?.doubleValue ?? 0
            let y = arguments["y"]?.doubleValue ?? 0
            return "Clicking (\(x),\(y))"
        case ToolNames.move:
            let x = arguments["x"]?.doubleValue ?? 0
            let y = arguments["y"]?.doubleValue ?? 0
            return "Moving to (\(x), \(y))"
        case ToolNames.captureScreen:
            return "Taking Screenshot"
        default:
            return "Unkown Tool Call"
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
        default: "error"
        }
    }
}
