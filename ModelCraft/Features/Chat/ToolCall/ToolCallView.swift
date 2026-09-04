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
    let videoProgress: LTXVideoProgress?

    init(
        toolCall: ToolCall,
        result: CallToolResult?,
        status: ToolCallStatus,
        videoProgress: LTXVideoProgress? = nil
    ) {
        self.toolCall = toolCall
        self.result = result
        self.status = status
        self.videoProgress = videoProgress
    }

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

        case ToolNames.readFile,
             ToolNames.writeFile,
             ToolNames.editFile:

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
                status: status,
                progress: videoProgress
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
