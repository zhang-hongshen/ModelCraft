//
//  ToolStatusView.swift
//  ModelCraft
//
//  Created by Hongshen on 15/5/26.
//

import SwiftUI
import MLXLMCommon

struct ToolStatusView: View {
    let toolCall: ToolCall
    let status: ToolCallStatus

    var body: some View {

        HStack {
            ToolCallIcon(toolCall: toolCall)
            Text(toolCall.localizedDescription(status))
        }
        .foregroundStyle(.secondary)
    }
}

/// A connector's call shows the app's own icon, so it reads as using that app.
struct ToolCallIcon: View {
    let toolCall: ToolCall

    @ScaledMetric(relativeTo: .body) private var appIconSize = 16

    var body: some View {
        if let connector = Connector(toolName: toolCall.function.name) {
            Image(connector.iconName)
                .resizable()
                .frame(width: appIconSize, height: appIconSize)
                .accessibilityHidden(true)
        } else {
            Image(systemName: toolCall.icon)
        }
    }
}

#Preview {
    ScrollView {
        VStack {
            let toolCall = ToolCall(function: .init(name: ToolNames.searchMap, arguments: ["query": "Beijing"]))
            
            ToolStatusView(toolCall: toolCall, status: .running)
            ToolStatusView(toolCall: toolCall, status: .completed)
            ToolStatusView(toolCall: toolCall, status: .failed)
        }.padding()
    }
    
}
