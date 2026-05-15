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
            if status == .running {
                ProgressView().controlSize(.small)
            }
            Text(toolCall.localizedDescription(status))
        }
        .font(.subheadline)
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
