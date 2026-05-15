//
//  FileToolRenderer.swift
//  ModelCraft
//
//  Created by Hongshen on 15/5/26.
//


import SwiftUI
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

    @State private var previewURL: URL? = nil
    
    var body: some View {

        if let url {

            Button {
                self.previewURL = url
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text(toolCall.localizedDescription(status))
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color.primary.opacity(0.05))
                .cornerRadius()
            }
            .buttonStyle(.plain)
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
