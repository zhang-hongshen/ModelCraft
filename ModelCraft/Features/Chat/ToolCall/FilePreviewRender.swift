//
//  FileToolRenderer.swift
//  ModelCraft
//
//  Created by Hongshen on 15/5/26.
//


import SwiftUI

struct FileToolRenderer: View {

    let toolCall: ToolCall
    let result: CallToolResult?
    let status: ToolCallStatus

    private var fileURL: URL? {

        guard let path = toolCall.function.arguments["path"]?.stringValue
        else {
            return nil
        }

        return try? PathResolver.resolve(path)
    }

    var body: some View {

        if let fileURL {

            Button {
                self.previewFileURL = url
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text(toolCall.localizedDescription(
                        toolCallStatus: status
                    ))
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
            .quickLookPreview($previewFileURL)
        }
    }
}
