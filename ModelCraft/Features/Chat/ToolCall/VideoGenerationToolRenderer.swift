//
//  VideoGenerationToolRenderer.swift
//  ModelCraft
//
//  Created by Hongshen on 15/5/26.
//

import SwiftUI
import AVKit
import MLXLMCommon

struct VideoGenerationToolRenderer: View {

    let toolCall: ToolCall
    let result: CallToolResult?
    let status: ToolCallStatus
    let progress: LTXVideoProgress?

    init(
        toolCall: ToolCall,
        result: CallToolResult?,
        status: ToolCallStatus,
        progress: LTXVideoProgress? = nil
    ) {
        self.toolCall = toolCall
        self.result = result
        self.status = status
        self.progress = progress
    }

    private var aspectRatio: CGFloat {
        let rawValue = toolCall.function.arguments["ratio"]?.stringValue
        let ratio = LTXVideoAspectRatio(rawValue: rawValue ?? "") ?? .landscape
        return CGFloat(ratio.value)
    }

    var body: some View {
        switch status {
        case .running:
            VideoGenerationLayout(aspectRatio: aspectRatio) {
                VideoGeneratingView(progress: progress)
            }

        case .completed:
            if let videoURL = result?.firstVideoURL {
                VideoGenerationLayout(aspectRatio: aspectRatio) {
                    GeneratedVideoView(url: videoURL)
                }
            } else if let result {
                ContentBlocksView(result: result)
            }

        default:
            ToolStatusView(toolCall: toolCall, status: status)
        }
    }
}

private struct VideoGenerationLayout<Content: View>: View {
    private static var maximumLength: CGFloat { 300 }

    let aspectRatio: CGFloat
    let content: Content

    init(aspectRatio: CGFloat, @ViewBuilder content: () -> Content) {
        self.aspectRatio = aspectRatio
        self.content = content()
    }

    var body: some View {
        content
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(
                width: aspectRatio >= 1 ? Self.maximumLength : nil,
                height: aspectRatio < 1 ? Self.maximumLength : nil)
    }
}

private struct VideoGeneratingView: View {
    let progress: LTXVideoProgress?

    private var fractionCompleted: Double? {
        guard case .generating(let completed, let total) = progress,
              total > 0
        else { return nil }
        return Double(completed) / Double(total)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.secondary.opacity(0.14),
                    Color.secondary.opacity(0.07),
                    Color.secondary.opacity(0.11),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)

            Image(systemName: "video.badge.sparkles")
                .font(.largeTitle)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary, Color.accentColor)

            HStack(spacing: 6) {
                progressText
                    .font(.headline)
                    .fontWeight(.semibold)
                if let fractionCompleted {
                    ProgressView(value: fractionCompleted)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.top, 16)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.quaternary)
        }
    }

    @ViewBuilder
    private var progressText: some View {
        Text(progress?.localizedDescription ?? String(localized: "Preparing..."))
    }
}

private struct GeneratedVideoView: View {
    let url: URL

    var body: some View {
        VideoPlayer(player: AVPlayer(url: url))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private extension CallToolResult {
    var firstVideoURL: URL? {
        content.lazy.compactMap { block in
            guard case .resourceLink(let link) = block,
                  link.mimeType?.hasPrefix("video") == true
            else {
                return nil
            }
            return link.url
        }.first
    }
}

#Preview {
    ScrollView {
        VStack {
            let toolCall = ToolCall(function: .init(
                name: ToolNames.textToVideo,
                arguments: [
                    "prompt": "A horse",
                    "ratio": "9:16",
                    "resolution": 512,
                    "duration_seconds": 1,
                ]))
            
            VideoGenerationToolRenderer(toolCall: toolCall, result: nil, status: .running)
            
            let video = URL.moviesDirectory.appendingPathComponent("1", conformingTo: .mpeg4Movie)
            let result = CallToolResult(content: [.resourceLink(ResourceLink(url: video, mimeType: "video/mp4"))])
            
            VideoGenerationToolRenderer(toolCall: toolCall, result: result, status: .completed)
            
            VideoGenerationToolRenderer(toolCall: toolCall, result: result, status: .failed)

        }
        .padding()
    }
}
