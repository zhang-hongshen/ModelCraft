//
//  ToolCallView.swift
//  ModelCraft
//
//  Created by Hongshen on 9/3/26.
//

import SwiftUI
import MLXLMCommon

struct ToolCallView: View {

    let toolCall: ToolCall
    let result: CallToolResult?
    let status: ToolCallStatus

    var body: some View {

        VStack(alignment: .leading, spacing: 12) {
            RendererView()
        }
    }

    @ViewBuilder
    func RendererView() -> some View {

        switch toolCall.function.name {

        case ToolNames.executeCommand:
            ExecuteCommandToolRenderer(
                toolCall: toolCall,
                result: result,
                status: status
            )

        case ToolNames.searchMap:
            MapToolRenderer(
                toolCall: toolCall,
                result: result,
                status: status
            )

        case ToolNames.readFromFile,
             ToolNames.writeToFile:

            FileToolRenderer(
                toolCall: toolCall,
                result: result,
                status: status
            )
            
        case ToolNames.textToImage:
            ImageGenerationToolRenderer(
                toolCall: toolCall,
                result: result,
                status: status
            )
            
        case ToolNames.textToVideo:
            VideoGenerationToolRenderer(
                toolCall: toolCall,
                result: result,
                status: status
            )

        default:
            DefaultToolRenderer(
                toolCall: toolCall,
                result: result,
                status: status
            )
        }
    }
}

#Preview {

    ScrollView {
        VStack {

            GroupBox("Text to Audio") {
                let toolCall = ToolCall(function: .init(name: ToolNames.textToVideo, arguments: [:]))
                let audio = URL.musicDirectory.appendingPathComponent("Piano", conformingTo: .mp3)

                let result = CallToolResult(content: [.resourceLink(ResourceLink(url: audio, mimeType: "audio/mpeg"))])
                ToolCallView(toolCall: toolCall, result: result, status: .completed)
            }

        }
        .padding()
    }
}
