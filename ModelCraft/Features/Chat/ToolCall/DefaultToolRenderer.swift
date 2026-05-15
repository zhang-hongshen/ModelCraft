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

    var body: some View {

        if let result {

            ContentBlocksView(result: result)

        } else {

            ToolStatusView(toolCall: toolCall, status: status)
        }
    }
}
