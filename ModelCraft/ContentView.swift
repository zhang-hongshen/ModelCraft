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
    
    // Possible values of the `currentTab` property.
    enum Tab: Hashable {
        case chat(Chat)
        case knowledgeBase(KnowledgeBase)
        case localModels, modelStore, prompts
    }
    
    @State private var modelTaskTimer: Timer? = nil
    @State private var modelTaskCancellables: Set<AnyCancellable> = []
    @State private var currentTab: Tab? = nil
    @State private var selectedKnowledgeBase: KnowledgeBase? = nil
    
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.downaloadedModels) private var models
    
    @Query(sort: \Chat.createdAt, order: .reverse) private var chats: [Chat]
    @Query(filter: ModelTask.predicateUnCompletedTask,
           sort: \ModelTask.createdAt,
           order: .reverse)
    var modelTasks: [ModelTask] = []
    @Query private var knowledgeBases: [KnowledgeBase] = []
    
    var body: some View {
        NavigationStack {
            NavigationSplitView {
                Sidebar()
            } detail: {
                Detail()
            }
            .task {
                modelTaskTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { timer in
                    guard timer.isValid else { return }
                    Task.detached { try await self.handleModelTask() }
                }
            }
            .sheet(item: $selectedKnowledgeBase) { knowledgeBase in
                KnowledgeBaseEdition(konwledgeBase: knowledgeBase)
            }
        }
    }
}

extension ContentView {
    
    @ViewBuilder
    func Sidebar() -> some View {
        List(selection: $currentTab) {
            ChatSection()
            KnowledgeBaseSection()
            ModelSection()
            PromptSection()
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 160, ideal: 170, max: 180)
        .safeAreaInset(edge: .bottom) {
            ServerStatusView().padding()
        }
    }
    
    @ViewBuilder
    func ChatSection() -> some View {
        Section {
            ForEach(chats) { chat in
                Text(chat.title).tag(Tab.chat(chat))
                    .contextMenu{
                        DeleteButton(style: .textOnly) {
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
                    .disabled(chats.last?.conversations.isEmpty ?? false)
            }
        }
    }
    
    @ViewBuilder
    func KnowledgeBaseSection() -> some View {
        Section {
            ForEach(knowledgeBases) { knowledgeBase in
                HStack {
                    Label(knowledgeBase.title, systemImage: knowledgeBase.icon)
                    if case .indexing = knowledgeBase.indexStatus {
                        Text("Indexing...").font(.footnote)
                    }
                }
                
                .tag(Tab.knowledgeBase(knowledgeBase))
                .contextMenu{
                    Button("Edit") {
                        selectedKnowledgeBase = knowledgeBase
                    }
                    DeleteButton(style: .textOnly) {
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
    
    @ViewBuilder
    func ModelSection() -> some View {
        Section {
            Label("Model Store", systemImage: "storefront").tag(Tab.modelStore)
            Label("Local Models", systemImage: "shippingbox").tag(Tab.localModels)
        } header: {
            Text("Model")
        }
    }
    
    @ViewBuilder
    func PromptSection() -> some View {
        Section {
            Label("Prompts", systemImage: "lightbulb.max").tag(Tab.prompts)
        } header: {
            Text("Prompts")
        }
    }
    
    @ViewBuilder
    func Detail() -> some View {
        switch currentTab {
        case .chat(let chat):
            ChatView(chat: chat).navigationTitle(chat.title)
        case .modelStore:
            ModelStore().navigationTitle("Model Store")
        case .knowledgeBase(let knowledgeBase):
            KnowledgeBaseDetailView(konwledgeBase: knowledgeBase)
                .navigationTitle(knowledgeBase.title)
        case .localModels:
            LocalModelsView().navigationTitle("Local Models")
        case .prompts:
            PromptsView()
        case .none:
            PromptSuggestionsView(minWidth: 270, onTapPromptCard: { _ in } )
        }
    }
}

extension ContentView {
    private func addChat() {
        withAnimation {
            if let isEmptyChat = chats.last?.conversations.isEmpty, isEmptyChat {
                return
            }
            let newChat = Chat()
            modelContext.persist(newChat)
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
        try deleteDupliateDownloadTask()
        for task in modelTasks.filter({ $0.status == .new}) {
            switch task.type {
            case .download: handleDownloadTask(task)
            case .delete: handleDeleteTask(task)
            }
        }
    }
    
    private func deleteDupliateDownloadTask() throws {
        // delete duplicate model download task
        let downloadedModelNames = Set(models.map { $0.name })
        for task in modelTasks.filter({ $0.type == .download && downloadedModelNames.contains($0.modelName) }) {
            modelContext.delete(task)
        }
        try modelContext.save()
    }
    
    func handleDownloadTask(_ task: ModelTask) {
        task.status = .running
        
        OllamaService.shared.pullModel(model: task.modelName)
            .sink { completion in
                switch completion {
                case .finished: task.status = .completed
                case .failure(_): task.status = .failed
                }
            } receiveValue: { response in
                print(response)
                if response.status == "success" {
                    print("Task completed")
                    task.status = .completed
                    return
                }
                if let completed = response.completed, let total = response.total {
                    task.value = Double(completed)
                    task.total = Double(total)
                }
            }.store(in: &modelTaskCancellables)
    }
    
    func handleDeleteTask(_ task: ModelTask) {
        task.status = .running
        OllamaService.shared.deleteModel(model: task.modelName)
            .sink { completion in
                switch completion {
                case .finished: task.status = .completed
                case .failure(_): task.status = .failed
                }
            } receiveValue: { _ in
                task.status = .completed
            }.store(in: &modelTaskCancellables)
    }
    
    func stopModelTask() {
        modelTasks.filter({ $0.status != .new})
            .forEach { $0.status = .stopped }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Chat.self, ModelTask.self],
                        inMemory: true)
        .environmentObject(GlobalStore())
}
