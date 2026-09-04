//
//  WebToolRenderer.swift
//  ModelCraft
//

import SwiftUI
import MLXLMCommon

struct WebToolRenderer: View {

    let toolCall: ToolCall
    let result: CallToolResult?
    let status: ToolCallStatus

    private var resultLink: ResourceLink? {
        result?.content.compactMap { block in
            guard case .resourceLink(let link) = block else { return nil }
            return link
        }.first
    }

    private var url: URL? {
        if let resultLink {
            return resultLink.url
        }
        guard let value = toolCall.function.arguments["url"]?.stringValue else {
            return nil
        }
        return URL(string: value)
    }

    private var title: String? {
        if let title = resultLink?.title, !title.isEmpty {
            return title
        }
        return url?.host ?? url?.absoluteString
    }

    var body: some View {
        if let url, let title {
            HStack(spacing: 4) {
                Image(systemName: toolCall.icon)
                if status == .running {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(toolCall.localizedDescription(status))

                Link(title, destination: url)
                    .underline()
            }
            .foregroundStyle(.secondary)
        }
    }
}
