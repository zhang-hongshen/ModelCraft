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
    @Bindable private var draft = Message(role: .user)
    @State private var selectedImages = Set<Data>()
    @State private var inspectorPresented = false
    @State private var inspectorContent = AnyView(EmptyView())
    
    @Environment(GlobalStore.self) private var globalStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    
    private let service = ChatService()
    private static let minWidth: CGFloat = 270
    
    var body: some View {
        MainView()
            .frame(minWidth: ChatView.minWidth, minHeight: 250)
            .toolbar(content: ToolbarItems)
            .safeAreaInset(edge: .bottom) {
                ChatInputView(
                    userInput: $draft,
                    trailing: {
                        HStack {
                            if chat?.sortedMessages.last?.status == .generating {
                                StopGenerateMessageButton()
                            } else {
                                SubmitMessageButton()
                            }
                        }
                    }
                )
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
        
        if availableModels.isEmpty {
            Text("No Models Available").disabled(true)
        } else {
            ForEach(availableModels) { model in
                Button {
                    globalStore.selectedModel = model
                } label: {
                    Text(model.displayName)
                    if globalStore.selectedModel == model {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    func KnowledgeBasePicker() -> some View {
        Button {
            globalStore.selectedKnowledgeBase = nil
        } label: {
            Label("None", systemImage: "circle.slash")
        }
        ForEach(knowledgeBases) { kb in
            Button {
                globalStore.selectedKnowledgeBase = kb
            } label: {
                Label(kb.title, systemImage: "book")
                if globalStore.selectedKnowledgeBase == kb {
                    Image(systemName: "checkmark")
                }
            }
        }
        
    }

    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Menu {
                Section("Active Model") {
                    ModelPicker()
                }
                
                Section("Knowledge Base") {
                    KnowledgeBasePicker()
                }
            } label: {
                VStack(alignment: .leading) {
                    Text(globalStore.selectedModel?.displayName ?? "Select Model")
                        .font(.headline)
                    if let kb = globalStore.selectedKnowledgeBase {
                        Text(kb.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .menuStyle(.button)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if sizeClass == .regular {
                Button {
                    withAnimation(.spring()) {
                        inspectorPresented.toggle()
                    }
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Toggle Info Sidebar")
            }
            
        }
    }
    
    
    @ViewBuilder
    func StopGenerateMessageButton() -> some View {
        Button {
            if let chat = chat {
                service.stopGenerating(chat: chat)
            }
        } label: {
            Image(systemName: "stop.circle.fill")
        }
    }
    
    @ViewBuilder
    func SubmitMessageButton() -> some View {
        let disabled = globalStore.selectedModel == nil || draft.content.isEmpty
        Button(action: submitDraft) {
            Image(systemName: "arrow.up.circle.fill")
        }
        .tint(disabled ? .secondary :  .primary)
        .disabled(disabled)
        .keyboardShortcut(.return, modifiers: .command)
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
                .onChange(of: chat.sortedMessages.last) {
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
