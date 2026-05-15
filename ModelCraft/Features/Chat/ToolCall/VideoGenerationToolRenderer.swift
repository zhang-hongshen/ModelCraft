//
//  VideoGenerationToolRenderer.swift
//  ModelCraft
//
//  Created by Hongshen on 15/5/26.
//

import SwiftUI
import MLXLMCommon

struct VideoGenerationToolRenderer: View {

    let toolCall: ToolCall
    let result: CallToolResult?
    let status: ToolCallStatus

    var body: some View {

        switch status {

        case .running:

            ToolStatusView(toolCall: toolCall, status: status)

        case .completed:

            if let result {
                ContentBlocksView(result: result)
            }

        default:

            ToolStatusView(toolCall: toolCall, status: status)
        }
    }
}

#Preview {
    ScrollView {
        VStack {
            let toolCall = ToolCall(function: .init(name: ToolNames.textToVideo, arguments: ["prompt": "A horse"]))
            
            VideoGenerationToolRenderer(toolCall: toolCall, result: nil, status: .running)
            
            let video = URL.moviesDirectory.appendingPathComponent("1", conformingTo: .mpeg4Movie)
            let result = CallToolResult(content: [.resourceLink(ResourceLink(url: video, mimeType: "video/mp4"))])
            
            VideoGenerationToolRenderer(toolCall: toolCall, result: result, status: .completed)
            
            VideoGenerationToolRenderer(toolCall: toolCall, result: result, status: .failed)

        }
        .padding()
    }
}
