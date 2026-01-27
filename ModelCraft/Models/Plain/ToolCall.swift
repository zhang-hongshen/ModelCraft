//
//  ToolCall.swift
//  ModelCraft
//
//  Created by Hongshen on 21/1/26.
//

import Foundation
import SwiftUI

struct ToolCall: Codable {
    let tool: ToolCallType
    let parameters: [String: Value]
    
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
}


extension ToolCall {
    
    var localizedName: LocalizedStringKey {
            let path = parameters["path"] ?? "Unknown"
            let command = parameters["command"] ?? "None"
            let url = parameters["url"] ?? ""
            let query = parameters["query"] ?? ""

            switch tool {
            case .readFromFile:
                return "Reading from file \(String(describing: path))"
            case .writeToFile:
                return "Writing to file \(String(describing: path))"
            case .executeCommand:
                return "Executing command \(String(describing: command))"
            case .composeEmail:
                return "Composing Email"
            case .composeMessage:
                return "Composing Message"
            case .openBrowser:
                return "Opening \(String(describing: url))"
            case .mapSearch:
                return "Searching for \(String(describing: query))"
            }
    }
    
    var icon: String {
        switch tool {
        case .readFromFile: "square.and.pencil"
        case .writeToFile: "square.and.pencil"
        case .executeCommand: "apple.terminal"
        case .composeEmail: "mail"
        case .composeMessage: "message"
        case .openBrowser: "link"
        case .mapSearch: "map"
        }
    }
}

enum ToolCallType: String, Codable {
    case readFromFile = "read_from_file"
    case writeToFile = "write_to_file"
    case executeCommand = "execute_command"
    case composeEmail = "compose_email"
    case composeMessage = "compose_message"
    case openBrowser = "open_browser"
    case mapSearch = "map_search"
}
