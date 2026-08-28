//
//  ImageGenerationToolRenderer.swift
//  ModelCraft
//
//  Created by Hongshen on 15/5/26.
//

import SwiftUI
import MLXLMCommon

struct ImageGenerationToolRenderer: View {

    let toolCall: ToolCall
    let result: CallToolResult?
    let status: ToolCallStatus

    var body: some View {

        switch status {

        case .running:

            ImageGeneratingView()
                .frame(height: 300)

        case .completed:

            if let result {
                ContentBlocksView(result: result)
            }

        default:

            ToolStatusView(toolCall: toolCall, status: status)
        }
    }
}

struct ImageGeneratingView: View {

    @State private var shimmerActive = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let s = min(w, h)
            let corner = s * 0.065
            let pad = s * 0.09
            let spacingMain = s * 0.055
            let spacingSub = s * 0.022
            let badge = s * 0.26
            let gridStep = s * 0.072
            let blurAmount = s * 0.2
            let glowEnd = max(w, h) * 0.62
            let hairline = s * 0.003

            ZStack {
                LinearGradient(
                    colors: [
                        Color.secondary.opacity(0.14),
                        Color.secondary.opacity(0.07),
                        Color.secondary.opacity(0.11)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(accentGlow(endRadius: glowEnd, startRadius: s * 0.02))
                    .blur(radius: blurAmount)
                    .opacity(0.85)

                GridPattern(step: gridStep, lineWidth: gridStep * 0.04)
                    .opacity(0.1)

                ShimmerOverlay(width: w, height: h)

                VStack(spacing: spacingMain) {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: badge, height: badge)

                        Circle()
                            .strokeBorder(.secondary.opacity(0.25), lineWidth: hairline)
                            .frame(width: badge, height: badge)

                        Image(systemName: "wand.and.stars")
                            .font(.title)
                            .fontWeight(.semibold)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.primary, Color.accentColor)
                            .minimumScaleFactor(0.35)
                            .frame(width: badge * 0.62, height: badge * 0.62)
                    }

                }
                .padding(pad)
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: hairline)
            }
            .overlay(alignment: .top) {
                HStack(spacing: spacingSub) {
                    Text("Generating image")
                        .font(.headline)
                        .fontWeight(.semibold)
                    ProgressView()
                        .controlSize(.small)
                }
                .foregroundStyle(.primary)
                .padding(.top, pad)
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(maxWidth: .infinity)
        .onAppear {
            shimmerActive = true
        }
    }

    private var cardFill: some ShapeStyle {
        AnyShapeStyle(
            LinearGradient(
                colors: [
                    Color.secondary.opacity(0.14),
                    Color.secondary.opacity(0.07),
                    Color.secondary.opacity(0.11)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func accentGlow(endRadius: CGFloat, startRadius: CGFloat) -> RadialGradient {
        RadialGradient(
            colors: [
                Color.accentColor.opacity(0.18),
                Color.accentColor.opacity(0.05),
                .clear
            ],
            center: .center,
            startRadius: startRadius,
            endRadius: endRadius
        )
    }
    
    @ViewBuilder
    private func GridPattern(step: CGFloat, lineWidth: CGFloat) -> some View {
        Canvas { context, size in
            var path = Path()
            stride(from: 0, through: size.width, by: step).forEach { x in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            stride(from: 0, through: size.height, by: step).forEach { y in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(.secondary), lineWidth: lineWidth)
        }
    }

    @ViewBuilder
    func ShimmerOverlay(width w: CGFloat, height h: CGFloat) -> some View {
        let band = w * 0.52
        let travel = w + band * 2
        let bandColor = Color.secondary.opacity(0.28)

        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: bandColor, location: 0.45),
                .init(color: bandColor.opacity(0.85), location: 0.55),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(width: band, height: h * 1.35)
        .rotationEffect(.degrees(-12))
        .offset(x: shimmerActive ? travel * 0.5 : -travel * 0.5)
        .position(x: w * 0.5, y: h * 0.5)
        .blendMode(.overlay)
        .allowsHitTesting(false)
        .animation(
            .linear(duration: 2.4).repeatForever(autoreverses: false),
            value: shimmerActive
        )
    }
}

#Preview("Image generation", traits: .preview) {
    let toolCall = ToolCall(function: .init(
        name: ToolNames.textToImage,
        arguments: ["prompt": "A horse"]
    ))
    let image = PreviewResources.png.url
    let result = CallToolResult(content: [
        .resourceLink(ResourceLink(url: image, mimeType: "image/png"))
    ])

    ScrollView {
        VStack {
            ImageGenerationToolRenderer(toolCall: toolCall, result: nil, status: .running)
            ImageGenerationToolRenderer(toolCall: toolCall, result: result, status: .completed)
        }
        .padding()
    }
}
