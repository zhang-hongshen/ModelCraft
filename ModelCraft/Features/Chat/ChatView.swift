//
//  ChatView.swift
//  ModelCraft
//
//  Created by Hongshen on 23/3/2024.
//

import SwiftUI
import SwiftData


struct ChatView: View {
    
    @State var chat: Chat?
    
    @Query private var availableModels: [LocalModel] = []
    @State private var draft = Message(role: .user)
    @State private var selectedImages = Set<Data>()
    @State private var isVoiceModeActive = false
    @State var voiceState: VoiceState = .idle
    
    enum VoiceState {
        case idle
        case loading
        case recording
    }
    
    @Environment(GlobalStore.self) private var globalStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(STTService.self) private var sttService
    
    private let chatService = ChatService()
    @Environment(STTService.self) private var service
    private static let minWidth: CGFloat = 270
    
    var body: some View {
        MainView()
            .frame(minWidth: ChatView.minWidth, minHeight: 250)
            .toolbar(content: ToolbarItems)
            .safeAreaInset(edge: .bottom) {
                ChatInputView(
                    userInput: draft,
                    trailing: {
                        HStack {
                            if let chat = chat, chat.isGenerating {
                                StopGenerateMessageButton()
                            } else {
                                if draft.content.isEmpty {
                                    voiceModeButton()
                                } else {
                                    SubmitMessageButton()
                                }
                            }
                        }
                    }
                )
                .safeAreaPadding()
                .background(.clear)
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

    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Menu {
                ModelPicker()
            } label: {
                VStack(alignment: .leading) {
                    Text(globalStore.selectedModel?.displayName ?? "Select Model")
                        .font(.headline)

                }
            }
            .menuStyle(.button)
        }
    }
    
    @ViewBuilder
    func voiceModeButton() -> some View {
        let disabled = globalStore.selectedModel == nil
        Button {
            Task {
                switch voiceState {
                case .idle:
                    voiceState = .loading
                    await sttService.loadModel()
                    await service.startRecording()
                    voiceState = .recording
                case .recording:
                    service.stopRecording()
                    voiceState = .idle

                case .loading:
                    break
                }
            }
        } label: {
            switch voiceState {
            case .loading:
                ProgressView()
            case .recording:
                Image(systemName: "stop.circle.fill")

            case .idle:
                Image(systemName: "waveform.circle.fill")
            }
        }
        .tint(voiceState == .recording
              ? .accentColor
              : (disabled ? .secondary : .primary))
        .disabled(disabled)
    }
    
    
    @ViewBuilder
    func StopGenerateMessageButton() -> some View {
        Button {
            if let chat = chat {
                chatService.stopGenerating(chat: chat)
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
                MessageView(message: message)
                    .scrollTargetLayout()
                    .environment(chatService)
            }
        }
    }
    
    @ViewBuilder
    func MainView() -> some View {
        if let chat = chat {
            ScrollViewReader { proxy in
                ScrollView {
                    MessagesView(chat.sortedMessages)
                    .safeAreaPadding()
                    
                    Text(service.transcript)
                        .padding()
                        .animation(.easeInOut, value: service.transcript)
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
            Text("How can I help you today?").font(.title.bold())
                .multilineTextAlignment(.leading)
        }
    }
    
}

extension ChatView {
    
    func submitDraft() {
        guard let model = globalStore.selectedModel else { return }
        let activeChat: Chat
        if let chat = chat {
            activeChat = chat
        } else {
            activeChat = chatService.createChat()
            globalStore.currentTab = .chat(activeChat)
        }
        let message = Message(role: .user, chat: activeChat,
                              content: draft.content, attachments: draft.attachments)
        clearDraft()
        Task {
            try await chatService.sendMessage(
                model: model,
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
        .environment(STTService())
        .modelContainer(ModelContainer.shared)
}


