//
//  FileToolRenderer.swift
//  ModelCraft
//
//  Created by Hongshen on 15/5/26.
//


import SwiftUI
import QuickLook
import MLXLMCommon

struct FileToolRenderer: View {

    let toolCall: ToolCall
    let result: CallToolResult?
    let status: ToolCallStatus

    private var url: URL? {

        guard let path = toolCall.function.arguments["path"]?.stringValue else {
            return nil
        }

        return PathResolver.resolve(path)
    }

    private var actionDescription: String {
        switch (toolCall.function.name, status) {
        case (ToolNames.writeToFile, .running):
            return String(localized: "Writing into")
        case (ToolNames.writeToFile, .completed):
            return String(localized: "Wrote into")
        case (ToolNames.writeToFile, .failed):
            return String(localized: "Failed to write into")
        case (ToolNames.readFromFile, .running):
            return String(localized: "Reading")
        case (ToolNames.readFromFile, .completed):
            return String(localized: "Read")
        default:
            return String(localized: "Failed to read")
        }
    }

    @State private var previewURL: URL? = nil
    
    var body: some View {

        if let url, let fileName = toolCall.fileDisplayName {
            HStack(spacing: 4) {
                Image(systemName: toolCall.icon)
                if status == .running {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(actionDescription)

                Button {
                    previewURL = url
                } label: {
                    Text(fileName)
                        .underline()
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.secondary)
            .quickLookPreview($previewURL)
        }
    }
}

#Preview {
    ScrollView {
        let toolCall = ToolCall(function: .init(name: ToolNames.readFromFile, arguments: ["path": "1.pdf"]))
        
        VStack {
            FileToolRenderer(toolCall: toolCall, result: nil, status: .running)
            
            let result = CallToolResult(content: [.text(TextContent(text: "total 0\ndrwxr-xr-x  2 user  staff   64 Sep  3 2026 ."))])
            FileToolRenderer(toolCall: toolCall, result: result, status: .completed)
            
            FileToolRenderer(toolCall: toolCall, result: nil, status: .failed)
        }
        .padding()
        
    }
}
