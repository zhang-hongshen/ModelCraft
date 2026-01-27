//
//  ToolExecutor.swift
//  ModelCraft
//
//  Created by Hongshen on 5/1/26.
//

import AppKit
import Foundation

class ToolExecutor {
    
    static let shared = ToolExecutor()
    
    func dispatch(_ toolCall: ToolCall) async -> CallToolResult {
        var res = CallToolResult(content: [])
        var parameters = toolCall.parameters
        do {
            switch toolCall.tool {
            case .readFromFile:
                guard let path = parameters["path"]?.stringValue else { break }
                res.content.append(.text(.init(text: try FileTool.readFromFile(path))))
            case .writeToFile:
                guard let path = parameters["path"]?.stringValue,
                   let content = parameters["content"]?.stringValue else {
                    break
                }
                try FileTool.writeToFile(path, content: content)
            case .executeCommand:
                guard let command = parameters["command"]?.stringValue else { break }
                res.content.append(.text(.init(text: try FileTool.executeCommand(command))))
            case .composeEmail:
                guard let recipients = parameters["recipients"]?.arrayValue?.compactMap({ $0.stringValue  }) else { break }
                AppTool.composeEmail(recipients: recipients,
                              subject: parameters["subject"]?.stringValue ?? "",
                              body: parameters["body"]?.stringValue ?? "")
                
            case .composeMessage:
                guard let recipients = parameters["recipients"]?.arrayValue?.compactMap({ $0.stringValue  }) else { break }
                AppTool.composeMessage(recipients: recipients,
                              body: parameters["body"]?.stringValue ?? "")
            case .openBrowser:
                guard let url = parameters["url"]?.stringValue else { break }
                AppTool.openBrowser(url: url)
            case .mapSearch:
                guard let query = parameters["query"]?.stringValue else { break }
                let useCurrentLocation = parameters["useCurrentLocation"]?.boolValue ?? false
                let places = try await MapTool.search(query: query, useCurrentLocation: useCurrentLocation)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted]
                let jsonData = try encoder.encode(places)
                let jsonString = String(data: jsonData, encoding: .utf8) ?? ""
                res.content.append(.text(.init(text: jsonString)))
            }
        } catch {
            print(error.localizedDescription)
            res = CallToolResult.error(error)
        }
        
        return res
    }
}

