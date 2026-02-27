//
//  ChatView.swift
//  ModelCraft
//
//  Created by Hongshen on 23/3/2024.
//

import SwiftUI
import SwiftData
import TipKit

struct ChatView: View {
    
    @State var chat: Chat?
    
    @Query private var knowledgeBases: [KnowledgeBase] = []
    
    @State private var draft = Message(role: .user)
    @State private var selectedImages = Set<Data>()
    @State private var inspectorPresented = false
    @State private var inspectorContent = AnyView(EmptyView())
    
    @Environment(GlobalStore.self) private var globalStore
    
    private let service = ChatService()
    private let minWidth: CGFloat = 270
    
    var body: some View {
        MainView()
            .frame(minWidth: minWidth,
                   minHeight: 250)
            .toolbar(content: ToolbarItems)
            .safeAreaInset(edge: .bottom) {
                ChatInputView(
                    chat: chat,
                    draft: $draft,
                    onSubmit: submitDraft,
                    onStop: {
                        if let chat = chat {
                            service.stopGenerating(chat: chat)
                        }
                    },
                    onUploadImages: uploadImages
                )
            }
            .onDrop(of: [.image], isTargeted: nil, perform: uploadImagesByDropping)
            .inspector(isPresented: $inspectorPresented){
                inspectorContent
                Spacer()
            }
            
    }
}

extension ChatView {
    
    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        
        @Bindable var globalStore = globalStore
        
        ToolbarItemGroup(placement: .principal) {
            if MLXService.availableModels.isEmpty {
                Text("No Available Model")
            } else {
                Picker("Models", selection: $globalStore.selectedModel) {
                    ForEach(MLXService.availableModels) { model in
                        Text(model.displayName).tag(model)
                    }
                }
            }
            Picker("Knowledge Base", selection: $globalStore.selectedKnowledgeBase) {
                ForEach(knowledgeBases) { knowledgeBase in
                    Text(verbatim: knowledgeBase.title).tag(knowledgeBase as KnowledgeBase?)
                }
                Text("None").tag(nil as KnowledgeBase?)
            }
        }
        
        ToolbarItemGroup {
            Button {
                inspectorPresented.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
        }
    }
    
    
    @ViewBuilder
    func MessagesView(_ messages: [Message]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(messages) { message in
                MessageView(message: message,
                            inspectorPresented: $inspectorPresented,
                            updateInspector: { content in
                    self.inspectorContent = AnyView(content)})
                .scrollTargetLayout()
                .environment(service)
            }
        }
    }
    
    @ViewBuilder
    func MainView() -> some View {
        if let chat = chat, !chat.messages.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    MessagesView(chat.sortedMessages)
                    .safeAreaPadding()
                }
                .contentMargins(.leading, Layout.padding, for: .scrollContent)
                .contentMargins(0, for: .scrollIndicators)
                .onChange(of: chat.messages) {
                    scrollToBottom(proxy)
                }
                .onChange(of: chat.messages.last) {
                    scrollToBottom(proxy)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollTargetBehavior(.paging)
        } else {
            WelcomeView()
        }
    }
    
}

extension ChatView {
    
    func uploadImagesByDropping(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            let progress = provider.loadDataRepresentation(for: .image) { dataOrNil, errorOrNil in
                guard let data = dataOrNil else { return }
                Task { @MainActor in
                    draft.images.append(data)
                }
            }
            debugPrint("progress: \(progress.fractionCompleted)%, total: \(progress.totalUnitCount)")
        }
        return true
    }
    
    func uploadImages(_ urls: [URL]) {
        for url in urls { 
            do {
                let data = try Data(contentsOf: url)
                self.draft.images.append(data)
            } catch {
                print("uploadImages error, \(error.localizedDescription)")
            }
        }
    }
    
    func submitDraft() {
        guard let model = globalStore.selectedModel else { return }
        let activeChat: Chat
        if let chat = chat {
            activeChat = chat
        } else {
            activeChat = service.createChat()
            globalStore.currentTab = .chat(activeChat)
        }
        let message = Message(role: .user, chat: activeChat,
                              content: draft.content, images: draft.images)
        clearDraft()
        Task {
            try await service.sendMessage(
                model: model,
                knowledgeBase: globalStore.selectedKnowledgeBase,
                chat: activeChat,
                message: message
            )
            
        }
    }
    
    func clearDraft() {
        draft.content = ""
        draft.images = []
    }
    
    func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let lastID = chat?.messages.last?.id else { return }
        withAnimation {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}

#Preview {
    ChatView(chat: Chat())
        .environment(GlobalStore())
}
