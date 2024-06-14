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
    @State private var selectedKnowledgeBase: KnowledgeBase? = nil
    
    // Possible values of the `chatStatus` property.
    
    enum ChatStatus {
        case assistantWaitingForRequest
        case userWaitingForResponse
        case assistantResponding
    }
    
    @State private var chatStatus: ChatStatus = .assistantWaitingForRequest
    @State private var cancellables = Set<AnyCancellable>()
    @State private var columns: [GridItem] = []
    @State private var promptSuggestions: [PromptSuggestion] = Array(PromptSuggestion.examples().shuffled().prefix(4))
    
    private let promptCardWidth: CGFloat = 250
    private let promptCardHorizontalSpacing: CGFloat = 20
    private let width: CGFloat = 270
    
    @Environment(\.modelContext) private var modelContext
    @Environment(\.serverStatus) private var serverStatus
    @Environment(\.downaloadedModels) private var models
    @Environment(\.selectedModel) private var selectedModel
    
    @AppStorage(UserDefaults.automaticallyScrollToBottom)
    private var automaticallyScrollToBottom = false
    
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
            .frame(minWidth: width,
                   minHeight: 250)
            .toolbar(content: ToolbarItems)
            .safeAreaInset(edge: .bottom, content: MessageEditionView)
            .onDrop(of: [.image], isTargeted: nil, perform: dropImages)
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
                chatStatus = .assistantResponding
            }
    }
}

extension ChatView {
    
    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            if models.isEmpty {
                Text("No Available Model")
            } else {
                Picker("Models", selection: selectedModel) {
                    ForEach(models, id: \.name) { model in
                        Text(verbatim: model.name).tag(model as ModelInfo?)
                    }
                }
            }
            Picker("Knowledge Base", selection: $selectedKnowledgeBase) {
                ForEach(knowledgeBases) { knowledgeBase in
                    Text(verbatim: knowledgeBase.title).tag(knowledgeBase as KnowledgeBase?)
                }
                Text("None").tag(nil as KnowledgeBase?)
            }
        }
    }
    
    @ViewBuilder
    func MainView() -> some View {
        if chat.messages.isEmpty {
            PromptSuggestionsView()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(chat.orderedMessages) { message in
                            MessageView(message: message).id(message.id)
                                .scrollTargetLayout()
                        }
                    }
                    .safeAreaPadding(.top, Default.padding)
                }
                .contentMargins(.leading, Default.padding, for: .scrollContent)
                .contentMargins(0, for: .scrollIndicators)
                .onChange(of: chat.messages) {
                    // don't scroll when user are scrolling
                    scrollToBottom(proxy)
                }
                .onChange(of: chat.orderedMessages.last?.content) {
                    if automaticallyScrollToBottom {
                        scrollToBottom(proxy)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
    
    @ViewBuilder
    func PromptSuggestionsView() -> some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .center) {
                    MessageRole.assistant.icon
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 200)
                    
                    Text("How can I help you today ?").font(.title.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    
                    LazyVGrid(columns: columns) {
                        ForEach(promptSuggestions) { prompt in
                            PromptCard(prompt: prompt, width: promptCardWidth)
                                .onTapGesture {
                                    submitPrompt(prompt)
                                }
                        }
                    }
                }
            }
            .contentMargins(0, for: .scrollIndicators)
            .onChange(of: proxy.size.width, initial: true) {
                let count = Int(proxy.size.width / width)
                withAnimation {
                    columns = Array(repeating: .init(.fixed(promptCardWidth),
                                                     spacing: promptCardHorizontalSpacing,
                                                     alignment: .top),
                                    count: count)
                }
            }
        }
    }
    
}

// MARK: - Message Edition

extension ChatView {
    
    @ViewBuilder
    func MessageEditionView() -> some View {
        MessageEditor()
            .safeAreaInset(edge: .leading) {
                UploadImageButton()
            }.safeAreaInset(edge: .trailing) {
                Group {
                    if chatStatus != .assistantWaitingForRequest {
                        StopGenerateMessageButton()
                    } else {
                        SubmitMessageButton()
                    }
                }
            }
            .imageScale(.large)
            .background(.ultraThinMaterial)
            .buttonStyle(.borderless)
            .safeAreaPadding()
    }
    
    @ViewBuilder
    func MessageEditor() -> some View {
        VStack(alignment: .leading) {
            if !draft.images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .center) {
                        ForEach(draft.images, id: \.self) { data in
                            ImageView(data: data) {
                                draft.images.removeAll { $0 == data }
                            }.frame(height: 50)
                        }
                    }
                }
            }
            
            TextEditor(text: $draft.content)
                .frame(maxHeight: 100)
                .fixedSize(horizontal: false, vertical: true)
                .font(.title3)
                .textEditorStyle(.plain)
        }
        .padding(Default.padding)
        .overlay {
            RoundedRectangle().fill(.clear).stroke(.primary, lineWidth: 1)
        }
    }
    
    @ViewBuilder
    func UploadImageButton() -> some View {
        Button {
            fileImporterPresented = true
        } label: {
            Image(systemName: "plus.circle")
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
        let disabled = selectedModel.wrappedValue == nil || draft.content.isEmpty
        Button(action: submitDraft) {
            Image(systemName: "arrow.up.circle.fill")
        }
        .tint(disabled ? .secondary : .accentColor)
        .disabled(disabled)
    }
}

extension ChatView {
    
    func dropImages(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            let progress = provider.loadDataRepresentation(for: .image) { dataOrNil, errorOrNil in
                guard let data = dataOrNil else { return }
                draft.images.append(data)
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
        guard let model = selectedModel.wrappedValue else {
            return
        }
        DispatchQueue.main.async {
            var humanMessage = HumanMessage.questionTemplate(context: "", question: message.content)
            if let knowledgeBase = selectedKnowledgeBase {
                let context = knowledgeBase.search(message.content)
                humanMessage = HumanMessage.questionTemplate(context: context, question: message.content)
            }
            chatStatus = .userWaitingForResponse
            let messages = SystemMessage.templates(model.name)
                            + chat.messages
                            + [humanMessage]
            message.chat = chat
            chat.messages.append(message)
            modelContext.persist(message)
            self.clearDraft()
            assistantMessage = Message(role: .assistant, status: .new)
            chat.messages.append(assistantMessage)
            OllamaService.shared.chat(model: model.name, messages: messages)
                .sink { completion in
                    switch completion {
                    case .finished: 
                        assistantMessage.status = .generated
                        self.resetChat()
                    case .failure(let error):
                        assistantMessage.status = .failed
                        self.resetChat()
                        debugPrint("error, \(error.localizedDescription)")
                    }
                } receiveValue: { response in
                    debugPrint("response, \(response)")
                    if case .userWaitingForResponse = chatStatus {
                        chatStatus = .assistantResponding
                        assistantMessage.status = .generating
                    }
                    assistantMessage.evalCount = response.evalCount
                    assistantMessage.evalDuration = response.evalDuration
                    assistantMessage.loadDuration = response.loadDuration
                    assistantMessage.promptEvalCount = response.promptEvalCount
                    assistantMessage.promptEvalDuration = response.promptEvalDuration
                    assistantMessage.totalDuration = response.totalDuration
                    
                    guard case .assistantResponding = chatStatus else { return }
                    if let message = response.message {
                        DispatchQueue.main.async {
                            assistantMessage.content.append(message.content)
                        }
                    }
                    if response.done {
                        resetChat()
                        assistantMessage.status = .generated
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
        guard let lastID = chat.orderedMessages.last?.id else { return }
        withAnimation {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}

#Preview {
    ChatView(chat: Chat())
}
