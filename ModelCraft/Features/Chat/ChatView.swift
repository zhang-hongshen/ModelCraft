//
//  ChatView.swift
//  ModelCraft
//
//  Created by Hongshen on 23/3/2024.
//

import SwiftUI
import SwiftData
import Combine
import TipKit

import OllamaKit

struct ChatView: View {
    
    @Bindable var chat: Chat
    
    @Query private var knowledgeBases: [KnowledgeBase] = []
    
    @State private var draft = Message(role: .user)
    @State private var assistantMessage = Message(role: .assistant, status: .new)
    @State private var selectedImages = Set<Data>()
    
    @State private var chatStatus: ChatStatus = .assistantWaitingForRequest
    @State private var cancellables = Set<AnyCancellable>()
    
    
    @Environment(GlobalStore.self) private var globalStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.downaloadedModels) private var models
    
    @AppStorage(UserDefaults.automaticallyScrollToBottom)
    private var automaticallyScrollToBottom = false
    
    private let minWidth: CGFloat = 270
    
    var body: some View {
        MainView()
            .frame(minWidth: minWidth,
                   minHeight: 250)
            .toolbar(content: ToolbarItems)
            .safeAreaInset(edge: .bottom) {
                ChatInputView(
                    draft: $draft,
                    chatStatus: $chatStatus,
                    onSubmit: submitDraft,
                    onStop: stopGenerateMessage,
                    onUploadImages: uploadImages
                )
            }
            .onDrop(of: [.image], isTargeted: nil, perform: uploadImagesByDropping)
            .onDisappear {
                cancellables.forEach { cancellable in
                  cancellable.cancel()
                }
                cancellables.removeAll()
                chatStatus = .assistantResponding
            }
    }
}

extension ChatView {
    
    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        
        @Bindable var globalStore = globalStore
        
        ToolbarItemGroup {
            if models.isEmpty {
                Text("No Available Model")
            } else {
                Picker("Models", selection: $globalStore.selectedModel) {
                    ForEach(models, id: \.name) { model in
                        Text(verbatim: model.name).tag(model.name)
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
    }
    
    @ViewBuilder
    func MainView() -> some View {
        if chat.conversations.isEmpty {
            WelcomeView(minWidth: minWidth,
                                  onTapPromptCard: submitPrompt)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(chat.conversations) { conversation in
                            ConversationView(conversation: conversation,
                                             chatStatus: $chatStatus)
                                .scrollTargetLayout()
                        }
                    }
                    .safeAreaPadding()
                }
                .contentMargins(.leading, Layout.padding, for: .scrollContent)
                .contentMargins(0, for: .scrollIndicators)
                .onChange(of: chat.conversations) {
                    // don't scroll when user are scrolling
                    scrollToBottom(proxy)
                }
                .onChange(of: chat.conversations.last) {
                    if automaticallyScrollToBottom {
                        scrollToBottom(proxy)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollTargetBehavior(.paging)
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
    
    func submitPrompt(_ prompt: PromptSuggestion) {
        let message = Message(role: .user,
                              content: prompt.prompt,
                              images: [])
        submitMessage(message)
    }
    
    func submitDraft() {
        let message = Message(role: .user,
                              content: self.draft.content,
                              images: self.draft.images)
        submitMessage(message)
    }
    
    func submitMessage(_ message: Message) {
        
        guard case .assistantWaitingForRequest = chatStatus else { return }
        guard let model = globalStore.selectedModel else {
            globalStore.errorWrapper = ErrorWrapper(error: AppError.noSelectedModel)
            return
        }
        Task {
            assistantMessage = Message(role: .assistant, status: .new)
            let conversation = Conversation(chat: chat,
                                            userMessage: message,
                                            assistantMessage: assistantMessage)
            message.conversation = conversation
            assistantMessage.conversation = conversation
            modelContext.insert([message, assistantMessage])
            modelContext.insert(conversation)
            try modelContext.save()
            let generateTitle = chat.conversations.isEmpty ? true : false
            DispatchQueue.main.async {
                chat.conversations.append(conversation)
                self.clearDraft()
                chatStatus = .userWaitingForResponse
            }
            

            var context = ""
            if let knowledgeBase = globalStore.selectedKnowledgeBase {
                context = await knowledgeBase.search(message.content).joined(separator: "\n")
            }
            let messages = chat.allMessages + [AgentPrompt.completeTask(context: context, task: message.content)]
            
            OllamaService.shared.chat(model: model,
                                      messages: messages.compactMap{ OllamaService.toChatRequestMessage($0) })
                .sink { completion in
                    DispatchQueue.main.async {
                        switch completion {
                        case .finished:
                            assistantMessage.status = .generated
                        case .failure(let error):
                            assistantMessage.status = .failed
                        }
                        self.resetChat()
                    }
                } receiveValue: { response in
                    DispatchQueue.main.async {
                        if case .userWaitingForResponse = chatStatus {
                            chatStatus = .assistantResponding
                            assistantMessage.status = .generating
                        }
                        
                        guard case .assistantResponding = chatStatus else { return }
                        if let messageContent = response.message?.content {
                            assistantMessage.content.append(messageContent)
                        }
                        if response.done {
                            resetChat()
                            assistantMessage.evalCount = response.evalCount
                            assistantMessage.evalDuration = response.evalDuration
                            assistantMessage.loadDuration = response.loadDuration
                            assistantMessage.promptEvalCount = response.promptEvalCount
                            assistantMessage.promptEvalDuration = response.promptEvalDuration
                            assistantMessage.totalDuration = response.totalDuration
                            assistantMessage.status = .generated
                            if generateTitle {
                                OllamaService.shared.chat(model: model,
                                                          messages: messages.compactMap{ OllamaService.toChatRequestMessage($0) })
                                    .sink { _ in }
                                receiveValue: { response in
                                    if let messageContent = response.message?.content {
                                        chat.title?.append(messageContent)
                                    }
                                }
                            }
                        }
                    }
                }
                .store(in: &cancellables)
        }
        
    }
    
    
    func stopGenerateMessage() {
        resetChat()
        assistantMessage.status = .generated
        cancellables.forEach { cancellable in
            cancellable.cancel()
        }
        cancellables.removeAll()
    }
    
    func clearDraft() {
        draft.content = ""
        draft.images = []
    }
    
    func resetChat() {
        chatStatus = .assistantWaitingForRequest
        assistantMessage = Message(role: .assistant, status: .new)
    }
    
    func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let lastID = chat.conversations.last?.id else { return }
        withAnimation {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}

#Preview {
    ChatView(chat: Chat())
        .environment(GlobalStore())
}
