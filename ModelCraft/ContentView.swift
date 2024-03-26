//
//  ContentView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 22/3/2024.
//

import SwiftUI
import SwiftData

import OrderedCollections
import ActivityIndicatorView

struct ContentView: View {
    
    @State private var selectedChat: Chat?
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Chat.createdAt, order: .reverse) private var chats: [Chat]
    
    private var groupChats: OrderedDictionary<Date, [Chat]> {
        let groupedDictionary = OrderedDictionary(grouping: chats) { (chat) -> Date in
            return Calendar.current.startOfDay(for: chat.createdAt)
        }
        
        return groupedDictionary
    }
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedChat) {
                ForEach(groupChats.elements, id: \.key) { (date, chats) in
                    Section {
                        ForEach(chats) { chat in
                            Text(chat.title).tag(chat)
                        }
                    } header: {
                        Text(date.daysAgoString())
                    }
                }
                .onDelete(perform: deleteChats)
            }
            .contextMenu(forSelectionType: Chat.self){ chats in
                if !chats.isEmpty {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        deleteChats(chats: chats)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .toolbar {
#if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
#endif
                ToolbarItem {
                    Button("New Chat", systemImage: "plus", action: addChat)
                        .disabled(chats.last?.messages.isEmpty ?? false)
                }
            }
        } detail: {
            ChatView(chat: $selectedChat)
                .navigationTitle(selectedChat?.title ?? "ModelCraft")
        }
    }
}

extension ContentView {
    private func addChat() {
        withAnimation {
            if let chat = chats.last, chat.messages.isEmpty {
                return
            }
            let newChat = Chat()
            modelContext.persist(newChat)
            selectedChat = newChat
        }
    }

    private func deleteChats(chats: Set<Chat>) {
        withAnimation {
            for chat in chats {
                modelContext.delete(chat)
            }
            try? modelContext.save()
        }
    }
    
    private func deleteChats(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(chats[index])
            }
            try? modelContext.save()
        }
    }
    

}

#Preview {
    ContentView()
        .modelContainer(for: Chat.self, inMemory: true)
}
