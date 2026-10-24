//
//  DefaultToolRenderer.swift
//  ModelCraft
//
//  Created by Hongshen on 15/5/26.
//

import SwiftUI
import MLXLMCommon


struct DefaultToolRenderer: View {

    let toolCall: ToolCall
    let result: CallToolResult?
    let status: ToolCallStatus

    @State private var isExpanded = false

    /// Text and embedded resources are model-facing output, so only media is worth expanding.
    private var mediaResult: CallToolResult? {
        guard let result else { return nil }
        let media = result.content.filter { block in
            switch block {
            case .image, .audio, .resourceLink: true
            case .text, .embeddedResource: false
            }
        }
        return media.isEmpty ? nil : CallToolResult(content: media)
    }

    var body: some View {

        if let mediaResult {
            DisclosureGroup(isExpanded: $isExpanded) {
                ContentBlocksView(result: mediaResult)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                label
            }

        } else if result != nil {

            label

        } else {

            ToolStatusView(toolCall: toolCall, status: status)
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            ToolCallIcon(toolCall: toolCall)
            Text(toolCall.compactDescription(status))
        }
        .foregroundStyle(.secondary)
    }
}
