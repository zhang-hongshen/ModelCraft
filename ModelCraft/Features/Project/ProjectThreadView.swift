//
//  ProjectThreadView.swift
//  ModelCraft
//
//  Created by Hongshen on 2/4/26.
//

import SwiftUI

struct ProjectThreadView: View {
    
    let threads: [Thread]
    @State private var thread: Thread? = nil
    
    var body: some View {
        VStack {
            ThreadView(thread: thread)
            List(selection: $thread) {
                ForEach(threads) { thread in
                    NavigationLink(value: thread) {
                        ThreadCard(thread: thread)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                }
            }
        }
    }
}

struct ThreadCard: View {
    let thread: Thread
    @State private var isHovered = false
    
    var body: some View {
        HStack {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.1))
                
                Image(systemName: "message.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.primary)
            }
            .frame(width: 44, height: 44)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(thread.title ?? String(localized: "New Chat"))
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Text(thread.displayCreatedAt)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                }
                
                Text(thread.conversation.first?.content ?? String(localized: "No messages"))
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isHovered = hovering
            }
        }
    }
}

#if DEBUG
#Preview(traits: .preview) {
    ProjectThreadView(threads: Thread.previews)
}
#endif
