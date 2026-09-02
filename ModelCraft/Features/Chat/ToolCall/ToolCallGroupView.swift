//
//  ToolCallGroupView.swift
//  ModelCraft
//

import SwiftUI

struct ToolCallGroupView: View {
    let messages: [Message]

    @State private var isExpanded = false

    private var summary: ToolCallGroupSummary {
        ToolCallGroupSummary(messages: messages)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(messages) { message in
                    if let toolCall = message.toolCall {
                        ToolCallView(
                            toolCall: toolCall,
                            result: message.toolCallResult,
                            status: message.toolCallStatus
                        )
                    }
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(summary.activeToolDescription ?? summary.completedDescription)
                .foregroundStyle(.secondary)
                .fontWeight(.medium)
                .multilineTextAlignment(.leading)
        }
    }
}

#Preview {
    let messages = Array(Chat.preview.sortedMessages.dropFirst(2).prefix(2))

    ScrollView {
        ToolCallGroupView(messages: messages)
            .padding()
            .frame(maxWidth: 560)
    }
}
