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
    @Environment(\.openURL) private var openURL

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

    /// Image files, such as screenshots, are shown as thumbnails beside the label rather than expanded.
    private var imageURLs: [URL]? {
        guard let mediaResult else { return nil }
        let urls = mediaResult.content.compactMap { block -> URL? in
            guard case .resourceLink(let link) = block, link.mimeType?.hasPrefix("image") == true else { return nil }
            return link.url
        }
        return urls.count == mediaResult.content.count ? urls : nil
    }

    var body: some View {

        if let imageURLs {
            HStack(spacing: 8) {
                label
                ForEach(imageURLs, id: \.self) { url in
                    Button {
                        openURL(url)
                    } label: {
                        FileThumbnail(url: url, frameWidth: 96)
                            .frame(height: 28)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open Image")
                    .fileContextMenu(url)
                }
            }

        } else if let mediaResult {
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
