//
//  ContextWindowUsageView.swift
//  ModelCraft
//
//  Created by Hongshen on 6/9/26.
//

import SwiftUI

struct ContextWindowUsageView: View {

    let chat: Chat
    let model: LocalModel

    @State private var isHovering = false
    @State private var usage: ContextUsage?

    private var tokenCount: Int { chat.tokenCount }
    private var contextWindow: Int { model.contextWindow }

    var body: some View {
        let fraction = min(Double(tokenCount) / Double(contextWindow), 1)

        // A circular ProgressView ignores the tint and draws a dark track that reads as full;
        // the capacity gauge is drawn by SwiftUI, so it takes the tint and scales to icon size.
        Gauge(value: fraction) {}
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint(for: fraction))
            .scaleEffect(0.4)
            .frame(width: 22, height: 22)
            .onHover { hovering in
                isHovering = hovering
            }
            .popover(
                isPresented: $isHovering,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .bottom
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Context window: \(Int(fraction * 100))% full")
                            .foregroundStyle(.secondary)

                        Text("\(formatTokens(tokenCount)) / \(formatTokens(contextWindow)) tokens used")
                            .font(.headline)
                    }

                    if let usage {
                        Divider()
                        breakdown(usage)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding()
                .task(id: tokenCount) {
                    usage = try? await ContextUsage.measure(chat: chat, model: model)
                }
            }
            .accessibilityLabel("Context window usage")
            .accessibilityValue(
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
            )
    }

    private func breakdown(_ usage: ContextUsage) -> some View {
        // Messages are the rest of the prompt, including chat-template formatting and media.
        let rows: [(title: LocalizedStringKey, tokens: Int, color: Color)] = [
            ("System prompt", usage.systemPrompt, .orange),
            ("Tools", usage.tools, .green),
            ("Messages", max(tokenCount - usage.systemPrompt - usage.tools, 0), .blue)
        ].sorted { $0.tokens > $1.tokens }

        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(rows, id: \.color) { row in
                self.row(row.title, tokens: row.tokens, color: row.color)
            }
        }
        .font(.callout)
    }

    private func row(_ title: LocalizedStringKey, tokens: Int, color: Color) -> some View {
        GridRow {
            Label {
                Text(title)
            } icon: {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 10, height: 10)
            }

            Text(formatTokens(tokens))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .gridColumnAlignment(.trailing)

            Text((Double(tokens) / Double(contextWindow)).formatted(.percent.precision(.fractionLength(1))))
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
        }
    }

    private func tint(for fraction: Double) -> Color {
        switch fraction {
        case 0.9...: .red
        case 0.75...: .orange
        default: .accent
        }
    }

    private func formatTokens(_ value: Int) -> String {
        if value >= 1_000 {
            return "\(Int((Double(value) / 1_000).rounded()))k"
        }

        return "\(value)"
    }
}
