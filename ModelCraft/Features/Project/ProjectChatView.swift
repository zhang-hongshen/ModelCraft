//
//  ProjectChatView.swift
//  ModelCraft
//
//  Created by Hongshen on 2/4/26.
//

import SwiftUI

struct ProjectChatView: View {
    
    let chats: [Chat]
    @State private var chat: Chat? = nil
    
    var body: some View {
        VStack {
            ChatView(chat: chat)
            List(selection: $chat) {
                ForEach(chats) { chat in
                    NavigationLink(value: chat) {
                        ChatCard(chat: chat)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                }
            }
        }
    }
}

struct ChatCard: View {
    let chat: Chat
    @State private var isHovered = false
    
    var body: some View {
        HStack {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.1))
                
                Image(systemName: "message.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 44, height: 44)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(chat.title ?? String(localized: "New Chat"))
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Text(chat.displayCreatedAt)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                }
                
                Text(chat.sortedMessages.first?.content ?? String(localized: "No messages"))
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

#Preview(traits: .preview) {
    ProjectChatView(chats: Chat.previews)
}
