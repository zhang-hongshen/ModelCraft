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


enum Tab: Hashable {
    case chat(Chat?), modelStore, knowledgeBase(KnowledgeBase)
}

struct ContentView: View {
    
    @State private var selectedChat: Chat?
    @State private var modelTaskTimer: Timer? = nil
    @State private var modelTaskCancellation: Set<AnyCancellable> = []
    
    @Environment(\.modelContext) private var modelContext
    
    @Query(sort: \Chat.createdAt, order: .reverse) private var chats: [Chat]
    @Query(sort: \ModelTask.createdAt, order: .reverse) var modelTasks: [ModelTask] = []
    @Query private var knowledgeBases: [KnowledgeBase] = []
    
    @State private var currentTab: Tab = .chat(nil)
    @State private var selectedKnowledgeBase: KnowledgeBase? = nil
    
    var body: some View {
        NavigationSplitView {
            List(selection: $currentTab) {
                ChatSection()
                KnowledgeBaseSection()
                Label("Model Store", systemImage: "storefront").tag(Tab.modelStore)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch currentTab {
            case .chat(let chat):
                ChatView(chat: chat)
                    .navigationTitle(chat?.title ?? Bundle.main.applicationName)
            case .modelStore:
                ModelStore().navigationTitle("Model Store")
            case .knowledgeBase(let knowledgeBase):
                KnowledgeBaseDetailView(konwledgeBase: knowledgeBase)
                    .navigationTitle(knowledgeBase.title)
            }
        }
        .task {
            modelTaskTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { timer in
                guard timer.isValid else { return }
                Task.detached { try self.handleModelTask() }
            }
        }
        .sheet(item: $selectedKnowledgeBase) { knowledgeBase in
            KnowledgeBaseEdition(konwledgeBase: knowledgeBase)
        }
    }
}

extension ContentView {
    
    @ViewBuilder
    func ChatSection() -> some View {
        Section {
            ForEach(chats) { chat in
                Text(chat.title).tag(Tab.chat(chat))
                    .contextMenu{
                        Button("Delete") {
                            modelContext.delete(chat)
                        }
                    }
            }
            .onDelete(perform: deleteChats)
        } header: {
            HStack {
                Text("Chat")
                Button(action: addChat, label: {
                    Image(systemName: "plus")
                }).buttonStyle(.borderless)
                .disabled(chats.last?.messages.isEmpty ?? false)
            }
        }
    }
    
    @ViewBuilder
    func KnowledgeBaseSection() -> some View {
        Section {
            ForEach(knowledgeBases) { knowledgeBase in
                Label(knowledgeBase.title,
                      systemImage: knowledgeBase.icon)
                .tag(Tab.knowledgeBase(knowledgeBase))
                .contextMenu{
                    Button("Edit") {
                        selectedKnowledgeBase = knowledgeBase
                    }
                    Button("Delete") {
                        modelContext.delete(knowledgeBase)
                    }
                }
            }
        } header: {
            HStack {
                Text("Knowledge Base")
                Button(action: {
                    selectedKnowledgeBase = KnowledgeBase()
                }, label: {
                    Image(systemName: "plus")
                }).buttonStyle(.borderless)
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
