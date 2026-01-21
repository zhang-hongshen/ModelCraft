//
//  ToolCall.swift
//  ModelCraft
//
//  Created by Hongshen on 21/1/26.
//

import Foundation

struct ToolCall: Codable {
    let tool: String
    let parameters: [String: String]
    
    init?(json: String) {
        guard let data = json.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
        do {
            let decoded = try JSONDecoder().decode(ToolCall.self, from: data)
            self.tool = decoded.tool
            self.parameters = decoded.parameters
        } catch {
            debugPrint("Invalid Tool Call: \(error.localizedDescription)")
            return nil
        }
    }
}


extension ToolCall {
    
    var localizedName: String {
        switch tool {
        case "read_from_file": "Reading from file \(parameters["path"] ?? "")"
        case "write_to_file": "Writing to file \(parameters["path"] ?? "")"
        case "execute_command": "Executing command \(parameters["command"] ?? "")"
        default: ""
        }
    }
    
    var icon: String {
        switch tool {
        case "read_from_file": "square.and.pencil"
        case "write_to_file": "square.and.pencil"
        case "execute_command": "apple.terminal"
        default: ""
        }
    }
}
