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

    @State private var isDetailPresented = false

    var body: some View {

        if let result {
            Button {
                isDetailPresented.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: toolCall.icon)
                    Text(toolCall.compactDescription(status))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isDetailPresented, arrowEdge: .leading) {
                ScrollView {
                    ContentBlocksView(result: result)
                        .textSelection(.enabled)
                }
                .frame(width: 520, height: 320)
                .padding(12)
            }

        } else {

            ToolStatusView(toolCall: toolCall, status: status)
        }
    }
}
