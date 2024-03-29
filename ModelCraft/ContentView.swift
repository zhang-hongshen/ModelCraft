//
//  ContentView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 22/3/2024.
//

import SwiftUI
import SwiftData
import Combine
import OrderedCollections
import ActivityIndicatorView

struct ContentView: View {
    
    
    @State private var selectedChat: Chat?
    @State private var modelTaskTimer: Timer? = nil
    @State private var modelTaskCancellation: Set<AnyCancellable> = []
    @State private var sheetPresented = false
    
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Chat.createdAt, order: .reverse) private var chats: [Chat]
    @Query(sort: \ModelTask.createdAt, order: .reverse) var modelTasks: [ModelTask] = []
    
    private let openStoreTip = OpenStoreTip()
    
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
                        Text(date.localizedDaysAgo)
                    }
                }
                .onDelete(perform: deleteChats)
            }
            .listStyle(.sidebar)
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
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("", systemImage: "shippingbox", action: { sheetPresented = true })
                        .buttonStyle(.borderless)
                        .popoverTip(openStoreTip, arrowEdge: .top)
                    Spacer()
                }.padding(Default.padding)
            }
            .sheet(isPresented: $sheetPresented) {
                ModelStore()
            }
        } detail: {
            ChatView(chat: $selectedChat)
                .navigationTitle(selectedChat?.title ?? Bundle.main.applicationName)
            
        }
        .task {
            modelTaskTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { timer in
                guard timer.isValid else { return }
                Task.detached { try self.handleModelTask() }
            }
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
    
    private func handleModelTask() throws {
        modelContext.delete(modelTasks.filter({ $0.status == .completed }))
        try modelContext.save()
        for task in modelTasks.filter({ $0.status == .new }) {
            @Bindable var task = task
            switch task.type {
            case .download: handleDownloadTask(task)
            case .delete: handleDeleteTask(task)
            }
        }
    }
    
    func handleDownloadTask(_ task: ModelTask) {
        task.status = .running
        OllamaService.shared.pullModel(model: task.modelName)
            .sink { completion in
                switch completion {
                case .finished: task.status = .completed
                case .failure(let error): debugPrint("failure \(error.localizedDescription)")
                }
            } receiveValue: { response in
                debugPrint("status: \(response.status), "
                           + "completed: \(String(describing: response.completed)), "
                           + "total: \(String(describing: response.total))")
                if response.status == "success" {
                    print("download completed")
                    task.status = .completed
                    return
                }
                if let completed = response.completed, let total = response.total {
                    task.value = Double(completed)
                    task.total = Double(total)
                }
            }.store(in: &modelTaskCancellation)
    }
    
    func handleDeleteTask(_ task: ModelTask) {
        Task.detached {
            task.status = .running
            try await OllamaService.shared.deleteModel(model: task.modelName)
            task.status = .completed
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Chat.self, inMemory: true)
}
