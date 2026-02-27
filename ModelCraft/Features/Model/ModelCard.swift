//
//  ModelCard.swift
//  ModelCraft
//
//  Created by Hongshen on 19/2/26.
//

import SwiftUI

struct ModelCard: View {
    
    let model: LMModel
    
    @State private var isHovered = false
    @Environment(\.modelContext) var modelContext
    
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
                
                Text(model.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Button {
                    
                } label: {
                    Text("Download")
                }

            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Layout.padding)
            .background(
                RoundedRectangle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(isHovered ? 0.2 : 0), radius: 5, x: 0, y: 2)
            )
            .overlay(
                RoundedRectangle()
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

extension ModelCard {
    
    func createDownloadModelTask() {
        switch model.configuration.id {
        case .id(let modelId, let revision):
            modelContext.persist(ModelTask(modelId: modelId, type: .download))
        case .directory(_):
            break
        }
    }
}
