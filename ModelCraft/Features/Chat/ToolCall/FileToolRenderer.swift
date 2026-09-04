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

        return FileTool.fileURL(for: path)
    }

    private var actionDescription: String {
        switch (toolCall.function.name, status) {
        case (ToolNames.writeFile, .running):
            return String(localized: "Writing into")
        case (ToolNames.writeFile, .completed):
            return String(localized: "Wrote into")
        case (ToolNames.writeFile, .failed):
            return String(localized: "Failed to write into")
        case (ToolNames.editFile, .running):
            return String(localized: "Editing")
        case (ToolNames.editFile, .completed):
            return String(localized: "Edited")
        case (ToolNames.editFile, .failed):
            return String(localized: "Failed to edit")
        case (ToolNames.readFile, .running):
            return String(localized: "Reading")
        case (ToolNames.readFile, .completed):
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
        let toolCall = ToolCall(function: .init(name: ToolNames.readFile, arguments: ["path": "1.pdf"]))
        
        VStack {
            FileToolRenderer(toolCall: toolCall, result: nil, status: .running)
            
            let result = CallToolResult(content: [.text(TextContent(text: "total 0\ndrwxr-xr-x  2 user  staff   64 Sep  3 2026 ."))])
            FileToolRenderer(toolCall: toolCall, result: result, status: .completed)
            
            FileToolRenderer(toolCall: toolCall, result: nil, status: .failed)
        }
        .padding()
        
    }
}
