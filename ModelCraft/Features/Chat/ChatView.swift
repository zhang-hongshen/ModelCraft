//
//  ChatView.swift
//  ModelCraft
//
//  Created by Hongshen on 23/3/2024.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ChatView: View {
    
    @State var chat: Chat?
    
    @Query private var knowledgeBases: [KnowledgeBase] = []
    @Query private var availableModels: [LocalModel] = []
    @State private var draft = Message(role: .user)
    @State private var selectedImages = Set<Data>()
    @State private var inspectorPresented = false
    @State private var inspectorContent = AnyView(EmptyView())
    
    @Environment(GlobalStore.self) private var globalStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    
    private let service = ChatService()
    private let minWidth: CGFloat = 270
    
    var body: some View {
        MainView()
            .frame(minWidth: minWidth,
                   minHeight: 250)
            .toolbar(content: ToolbarItems)
            .safeAreaInset(edge: .bottom) {
                VStack {
                    
                    if sizeClass == .compact {
                        KnowledgeBasePicker()
                    }
                    
                    ChatInputView(
                        chat: chat,
                        draft: $draft,
                        onSubmit: submitDraft,
                        onStop: {
                            if let chat = chat {
                                service.stopGenerating(chat: chat)
                            }
                        },
                        onUpload: { draft.attachments.append(contentsOf: $0) }
                    )
                }
            }
            .onDrop(of: [.image, .movie], isTargeted: nil, perform: uploadByDropping)
            .toolInspector(isPresented: $inspectorPresented){
                inspectorContent
                Spacer()
            }
            
    }
}

extension ChatView {
    
    @ViewBuilder
    func ModelPicker() -> some View {
        @Bindable var globalStore = globalStore
        
        if availableModels.isEmpty {
            Text("No Available Model")
        } else {
            Picker("Models", selection: $globalStore.selectedModel) {
                ForEach(availableModels) { model in
                    Text(model.displayName).tag(model)
                }
                Text("No selected model").tag(nil as LocalModel?)
            }
        }
    }
    
    @ViewBuilder
    func KnowledgeBasePicker() -> some View {
        @Bindable var globalStore = globalStore
        
        Picker("Knowledge Base", selection: $globalStore.selectedKnowledgeBase) {
            ForEach(knowledgeBases) { knowledgeBase in
                Text(verbatim: knowledgeBase.title).tag(knowledgeBase as KnowledgeBase?)
            }
            Text("No selected knowledge base").tag(nil as KnowledgeBase?)
        }
    }
    
    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        
        ToolbarItem(placement: .principal) {
            ModelPicker()
        }
        
        
        if sizeClass == .regular {
            ToolbarItem(placement: .principal) {
                KnowledgeBasePicker()
            }
        
            ToolbarItem {
                Button {
                    inspectorPresented.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
            }
        } else {
            ToolbarItem {
                NavigationLink {
                    ModelStore()
                } label: {
                    Image(systemName: "storefront")
                }

            }
        }
        
    }
    
    
    @ViewBuilder
    func MessagesView(_ messages: [Message]) -> some View {
        LazyVStack(alignment: .leading, spacing: 10) {
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
    
    func uploadByDropping(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil)
                else { return }
                
                draft.attachments.append(url)
            }
        }
        return true
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
                              content: draft.content, attachments: draft.attachments)
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
        draft.attachments = []
    }
    
    func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let lastID = chat?.sortedMessages.last?.id else { return }
        withAnimation {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}

#Preview {
    ChatView(chat: Chat())
        .environment(GlobalStore())
        .modelContainer(ModelContainer.shared)
}
