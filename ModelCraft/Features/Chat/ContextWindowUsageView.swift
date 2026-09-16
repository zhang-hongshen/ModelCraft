//
//  ContextWindowUsageView.swift
//  ModelCraft
//
//  Created by Hongshen on 6/9/26.
//

import SwiftUI

struct ContextWindowUsageView: View {

    let tokenCount: Int
    let contextWindow: Int

    @State private var isHovering = false

    var body: some View {
        let fraction = min(Double(tokenCount) / Double(contextWindow), 1)

        ProgressView(value: fraction)
            .controlSize(.small)
            .onHover { hovering in
                isHovering = hovering
            }
            .popover(
                isPresented: $isHovering,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .bottom
            ) {
                VStack(spacing: 8) {
                    Text("Context window:")
                        .foregroundStyle(.secondary)

                    Text("\(Int(fraction * 100))% full")
                        .foregroundStyle(.secondary)

                    Text("\(formatTokens(tokenCount)) / \(formatTokens(contextWindow)) tokens used")
                        .font(.headline)
                }
                .padding()
            }
            .accessibilityLabel("Context window usage")
            .accessibilityValue(
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
            )
    }

    private func formatTokens(_ value: Int) -> String {
        if value >= 1_000 {
            return "\(Int((Double(value) / 1_000).rounded()))k"
        }

        return "\(value)"
    }
}
