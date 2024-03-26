//
//  PromptCard.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 25/3/2024.
//

import SwiftUI

struct PromptCard: View {
    
    var prompt: Prompt
    var width: CGFloat

    @State private var isHovering = false
    
    var body: some View {
        ZStack {
            RoundedRectangle().fill(.selection).opacity(isHovering ? 1 : 0)
            VStack(alignment: .leading) {
                Text(prompt.title).font(.headline).lineLimit(1)
                Text(prompt.description).lineLimit(1).foregroundStyle(.secondary)
            }
            .padding()
            RoundedRectangle().stroke(.primary, lineWidth: 1)
        }
        .frame(width: width)
        .onHover(perform: { isHovering = $0 })
        
    }
}

#Preview {
    PromptCard(prompt: Prompt(title: "title", description: "description", prompt: "prompt"),
               width: 200)
}
