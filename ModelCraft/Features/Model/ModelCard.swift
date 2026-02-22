//
//  ModelCard.swift
//  ModelCraft
//
//  Created by Hongshen on 19/2/26.
//

import SwiftUI
import OllamaKit

struct ModelCard: View {
    
    let model: ModelInfo
    @State private var isHovered = false
    
    var body: some View {
        NavigationLink(value: model.name) {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.1))
                        .frame(width: 60, height: 60)
                    
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.accentColor)
                }
                
                Text(model.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Text("Ollama Model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(isHovered ? 0.2 : 0), radius: 5, x: 0, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor.opacity(isHovered ? 0.5 : 0), lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}
