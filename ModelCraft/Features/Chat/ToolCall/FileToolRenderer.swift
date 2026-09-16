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

    private var readActionDescription: String {
        switch status {
        case .running:
            return String(localized: "Reading")
        case .completed:
            return String(localized: "Read")
        case .failed:
            return String(localized: "Failed to read")
        }
    }

    private func actionDescription(for action: PatchFileAction) -> String {
        switch (action, status) {
        case (.edit, .running):
            return String(localized: "Editing")
        case (.edit, .completed):
            return String(localized: "Edited")
        case (.edit, .failed):
            return String(localized: "Failed to edit")
        case (.delete, .running):
            return String(localized: "Deleting")
        case (.delete, .completed):
            return String(localized: "Deleted")
        case (.delete, .failed):
            return String(localized: "Failed to delete")
        }
    }

    @State private var previewURL: URL? = nil
    
    var body: some View {

        if toolCall.function.name == ToolNames.readFile,
           let path = toolCall.function.arguments["path"]?.stringValue,
           let fileName = toolCall.fileDisplayName {
            HStack(spacing: 4) {
                Image(systemName: toolCall.icon)
                Text(readActionDescription)

                Button {
                    previewURL = FileTool.fileURL(for: path)
                } label: {
                    Text(fileName)
                        .underline()
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.secondary)
            .quickLookPreview($previewURL)
        } else if toolCall.function.name == ToolNames.applyPatch {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(toolCall.patchFileChanges) { change in
                    HStack(spacing: 4) {
                        Image(systemName: toolCall.icon)
                        Text(actionDescription(for: change.action))

                        if change.action == .edit {
                            Button {
                                previewURL = FileTool.fileURL(for: change.path)
                            } label: {
                                Text(change.fileName)
                                    .underline()
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(change.fileName)
                        }
                    }
                }
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
