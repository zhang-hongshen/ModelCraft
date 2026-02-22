//
//  ToolExecutor.swift
//  ModelCraft
//
//  Created by Hongshen on 5/1/26.
//

import AppKit
import Foundation
import SwiftData

class ToolExecutor {
    
    static let shared = ToolExecutor()
    
    private let knowledgaBaseModelActor = KnowledgaBaseModelActor(modelContainer: ModelContainer.shared)
    
    func dispatch(_ toolCall: ToolCall) async -> CallToolResult {
        var res = CallToolResult.success()
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
                let result = try FileTool.executeCommand(command)
                if !result.stdout.isEmpty {
                    res.content.append(.text(TextContent(text: result.stdout)))
                }
                if !result.stderr.isEmpty {
                    res.content.append(.text(TextContent(text: result.stderr)))
                }
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
            case .searchMap:
                guard let query = parameters["query"]?.stringValue else { break }
                let useCurrentLocation = parameters["useCurrentLocation"]?.boolValue ?? false
                let places = try await SearchTool.searchMap(query: query, useCurrentLocation: useCurrentLocation)
                res.content.append(.text(.init(text: try places.toString())))
            case .searchRelevantDocuments:
                guard let query = parameters["query"]?.stringValue,
                      let (_, data) = parameters["knowledge_base_id"]?.dataValue else { break }
                let knowledgeBaseID = try JSONDecoder().decode(PersistentIdentifier.self, from: data)
                let docs = await knowledgaBaseModelActor.searchRelevantDocuments(knowledgeBaseID: knowledgeBaseID, query: query)
                res.content.append(.text(TextContent(text: try docs.toString())))
            case .executeAppleScript:
                guard let script = parameters["script"]?.stringValue else { break }
                res.content.append(.text(TextContent(text: try AppTool.executeAppleScript(script))))
            case .captureScreen:
                guard let (image, mimeType) = await ScreenControlManager.shared.taskScreenshot() else { break }
                res.content.append(.image(ImageContent(data: image.base64EncodedString(), mimeType: mimeType)))
            case .click:
                guard let x = parameters["x"]?.doubleValue,
                        let y = parameters["y"]?.doubleValue else { break }
                await ScreenControlManager.shared.click(x: x, y: y)
            case .move:
                guard let x = parameters["x"]?.doubleValue,
                        let y = parameters["y"]?.doubleValue else { break }
                await ScreenControlManager.shared.move(x: x, y: y)
            }
        } catch {
            print(error.localizedDescription)
            res = CallToolResult.error(error)
        }
        
        return res
    }
}

