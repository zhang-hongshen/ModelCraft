//
//  ChatView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 23/3/2024.
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
    @State private var fileImporterPresented = false
    
    @State private var chatStatus: ChatStatus = .assistantWaitingForRequest
    @State private var cancellables = Set<AnyCancellable>()
    
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var globalStore: GlobalStore
    @Environment(\.downaloadedModels) private var models
    
    @AppStorage(UserDefaults.automaticallyScrollToBottom)
    private var automaticallyScrollToBottom = false
    
    private let minWidth: CGFloat = 270
    
    var body: some View {
        MainView()
            .overlay(alignment: .bottom) {
                PromptSearchView(searchText: $draft.content) {
                    draft.content = $0
                }
                .frame(maxHeight: 90)
                .background(.ultraThinMaterial)
                .cornerRadius()
                .padding(.horizontal)
            }
            .frame(minWidth: minWidth,
                   minHeight: 250)
            .toolbar(content: ToolbarItems)
            .safeAreaInset(edge: .bottom, content: MessageEditor)
            .onDrop(of: [.image], isTargeted: nil, perform: uploadImagesByDropping)
            .fileImporter(isPresented: $fileImporterPresented,
                          allowedContentTypes: [.image],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): uploadImages(urls)
                case .failure(let error): debugPrint(error.localizedDescription)
                }
            }.onDisappear {
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
            PromptSuggestionsView(minWidth: minWidth,
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
                .contentMargins(.leading, Default.padding, for: .scrollContent)
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

// MARK: - Message Edition

extension ChatView {
    
    @ViewBuilder
    func MessageEditor() -> some View {
        VStack(alignment: .leading) {
            if !draft.images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .center) {
                        ForEach(draft.images, id: \.self) { data in
                            ImageView(data: data) {
                                draft.images.removeAll { $0 == data }
                            }.frame(height: 80)
                        }
                    }
                }
            }
            
            TextEditor(text: $draft.content)
                .frame(maxHeight: 100)
                .fixedSize(horizontal: false, vertical: true)
                .font(.title3)
                .textEditorStyle(.plain)
            HStack {
                UploadImageButton()
                Spacer()
                Group {
                    if chatStatus != .assistantWaitingForRequest {
                        StopGenerateMessageButton()
                    } else {
                        SubmitMessageButton()
                    }
                }
            }
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
        .padding()
        .overlay {
            RoundedRectangle().fill(.clear).stroke(.primary, lineWidth: 1)
        }
        .safeAreaPadding()
        .background(.regularMaterial)
    }
    
    @ViewBuilder
    func UploadImageButton() -> some View {
        Button {
            fileImporterPresented = true
        } label: {
            Image(systemName: "plus")
        }
    }
    
    @ViewBuilder
    func StopGenerateMessageButton() -> some View {
        Button(action: stopGenerateMessage) {
            Image(systemName: "stop.circle.fill")
        }
    }
    
    @ViewBuilder
    func SubmitMessageButton() -> some View {
        let disabled = globalStore.selectedModel == nil || draft.content.isEmpty
        Button(action: submitDraft) {
            Image(systemName: "arrow.up.circle.fill")
        }
        .tint(disabled ? .secondary : .accentColor)
        .disabled(disabled)
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
            DispatchQueue.main.async {
                chat.conversations.append(conversation)
                self.clearDraft()
                chatStatus = .userWaitingForResponse
            }
            
            let userMessage = UserMessage.question(message.content)
            var systemMessages = [SystemMessage.characterSetting(model),
                                  SystemMessage.respondRule]
            if let knowledgeBase = globalStore.selectedKnowledgeBase {
                let context = await knowledgeBase.search(message.content).joined(separator: " ")
                systemMessages.append(SystemMessage.retrivedContent(context))
            }
            let messages = systemMessages + chat.allMessages + [userMessage]
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
                        if let message = response.message {
                            assistantMessage.content.append(message.content)
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
}
