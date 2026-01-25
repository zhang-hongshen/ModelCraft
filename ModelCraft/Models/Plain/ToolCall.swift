//
//  ToolCall.swift
//  ModelCraft
//
//  Created by Hongshen on 21/1/26.
//

import Foundation

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
    
    var localizedName: String {
        switch tool {
        case .readFromFile: "Reading from file \(parameters["path"] ?? "")"
        case .writeToFile: "Writing to file \(parameters["path"] ?? "")"
        case .executeCommand: "Executing command \(parameters["command"] ?? "")"
        case .composeEmail: "Composing Email"
        case .composeMessage: "Composing Message"
        case .openBrowser: "Opening Browser"
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
}
