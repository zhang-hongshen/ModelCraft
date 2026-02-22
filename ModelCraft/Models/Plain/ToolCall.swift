//
//  ToolCall.swift
//  ModelCraft
//
//  Created by Hongshen on 21/1/26.
//

import Foundation
import SwiftUI

struct ToolCall: Codable {
    let tool: ToolCallName
    var parameters: [String: Value]
    
    init?(json: String) {
        guard let data = json.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
        do {
            let decoded = try JSONDecoder().decode(ToolCall.self, from: data)
            self.tool = decoded.tool
            self.parameters = decoded.parameters
        } catch {
//            debugPrint("Invalid Tool Call: \(error.localizedDescription)")
            return nil
        }
    }
    
    init(tool: ToolCallName, parameters: [String: Value] = [:]) {
        self.tool = tool
        self.parameters = parameters
    }
    
}


extension ToolCall {
    
    var localizedName: LocalizedStringKey {
        switch tool {
        case .readFromFile:
            let path = parameters["path"]?.stringValue ?? "Unknown"
            return "Reading from file \(String(describing: path))"
        case .writeToFile:
            let path = parameters["path"]?.stringValue ?? "Unknown"
            return "Writing to file \(String(describing: path))"
        case .executeCommand:
            let command = parameters["command"]?.stringValue ?? "None"
            return "Executing command \(String(describing: command))"
        case .composeEmail:
            return "Composing Email"
        case .composeMessage:
            return "Composing Message"
        case .openBrowser:
            let url = parameters["url"]?.stringValue ?? ""
            return "Opening \(String(describing: url))"
        case .searchMap:
            let query = parameters["query"]?.stringValue ?? ""
            return "Searching for \(String(describing: query))"
        case .searchRelevantDocuments:
            let query = parameters["query"]?.stringValue ?? ""
            return "Search for \(String(describing: query))"
        case .executeAppleScript:
            return "Executing Script"
        case .click:
            let x = parameters["x"]?.doubleValue ?? 0
            let y = parameters["y"]?.doubleValue ?? 0
            return "Clicking (\(x),\(y))"
        case .move:
            let x = parameters["x"]?.doubleValue ?? 0
            let y = parameters["y"]?.doubleValue ?? 0
            return "Moving to (\(x), \(y))"
        case .captureScreen:
            return "Taking Screenshot"
        }
    }
    
    var icon: String {
        switch tool {
        case .readFromFile: "square.and.pencil"
        case .writeToFile: "square.and.pencil"
        case .executeCommand, .executeAppleScript: "apple.terminal"
        case .composeEmail: "mail"
        case .composeMessage: "message"
        case .openBrowser: "link"
        case .searchMap: "map"
        case .searchRelevantDocuments: "magnifyingglass"
        case .click, .move: "pointer.arrow"
        case .captureScreen: "camera"
        }
    }
}
