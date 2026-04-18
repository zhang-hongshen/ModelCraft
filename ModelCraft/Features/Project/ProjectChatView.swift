//
//  ProjectChatView.swift
//  ModelCraft
//
//  Created by Hongshen on 2/4/26.
//

import SwiftUI

struct ProjectChatView: View {
    @State var chats: [Chat]
    @State private var selectedChats: Set<Chat> = []
    
    var body: some View {
        NavigationStack {
            List(selection: $selectedChats) {
                ForEach(chats) { chat in
                    NavigationLink(value: chat) {
                        ChatCard(chat: chat)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            }
            .listStyle(.plain)
            .navigationDestination(for: Chat.self) { chat in
                ChatView(chat: chat)
            }
        }
    }
}

struct ChatCard: View {
    let chat: Chat
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 12) {
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
                    Text(chat.title ?? "New Chat")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Text(chat.displayCreatedAt)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                }
                
                Text(chat.sortedMessages.first?.content ?? "No messages")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.primary.opacity(isHovered ? 0.15 : 0.05), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(isHovered ? 0.05 : 0), radius: 10, x: 0, y: 5)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isHovered = hovering
            }
        }
    }
}

#Preview {
    ProjectChatView(chats: [
        Chat(title: "Make a plan"),
        Chat(title: "Do a job")
    ])
}
