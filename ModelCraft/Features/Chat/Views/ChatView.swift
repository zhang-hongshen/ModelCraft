//
//  ChatView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 23/3/2024.
//

import SwiftUI
import Combine
import ActivityIndicatorView

struct ChatView: View {
    
    @Binding var chat: Chat?
    
    @State private var models: [ModelInfo] = []
    @State private var selectedModel: ModelInfo? = nil
    @State private var draft = Message()
    @State private var selectedImages = Set<Data>()
    @State private var fileImporterPresented = false
    
    // Possible values of the `chatStatus` property.
    
    enum ChatStatus {
        case assistantWaitingForRequest
        case userWaitingForResponse
        case assistantResponding
    }
    
    @State private var chatStatus: ChatStatus = .assistantWaitingForRequest
    @State private var cancellables = Set<AnyCancellable>()
    @State private var columns: [GridItem] = []
    private let promptCardIdealWidth: CGFloat = 250
    
    @Environment(\.modelContext) private var modelContext
    @Environment(\.serverStatus) private var serverStatus
    
    var body: some View {
        MainView()
            .frame(minWidth: promptCardIdealWidth, minHeight: 250)
            .toolbar(content: ToolbarItems)
            .safeAreaInset(edge: .bottom, content: MessageInput)
            .onDrop(of: [.image], isTargeted: nil) { providers in
                for provider in providers {
                    provider.loadDataRepresentation(for: .image) { dataOrNil, errorOrNil in
                        guard let data = dataOrNil else { return }
                        DispatchQueue.main.async {
                            draft.images.append(data)
                        }
                    }
                }
                return true
            }
            .onAppear(perform: { print("onAppear") })
            .onDisappear(perform: { print("onDisappear") })
            .fileImporter(isPresented: $fileImporterPresented,
                          allowedContentTypes: [.image],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    uploadImages(urls)
                case .failure(let error):
                    debugPrint(error.localizedDescription)
                }
            }
            .task { fetchLocalModels() }
        
    }
}

extension ChatView {
    
    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Models", selection: $selectedModel) {
                ForEach(models, id: \.name) { model in
                    Text(verbatim: model.name).tag(model as ModelInfo?)
                }
                Text("No Available Model").tag(nil as ModelInfo?)
            }
        }
        ToolbarItem(placement: .status) {
            ServerStatusView()
        }
    }
    @ViewBuilder
    func MainView() -> some View {
        if let chat = chat, !chat.messages.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(content: MessageList)
                .onChange(of: chat.messages) {
                    scrollToBottom(proxy)
                }
                .onChange(of: chat.orderedMessages.last?.content) {
                    scrollToBottom(proxy)
                }
            }
            .scrollDismissesKeyboard(.interactively)
        } else {
            PromptView()
        }
    }
    
    @ViewBuilder
    func PromptView() -> some View {
        GeometryReader { proxy in
            ScrollView {
                MessageRole.assistant.icon
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 200)
                Text("How can I help you today ?").font(.title.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                LazyVGrid(columns: columns) {
                    ForEach(Prompt.examples().prefix(4)) { prompt in
                        PromptCard(prompt: prompt, width: promptCardIdealWidth)
                            .onTapGesture {
                                submitPrompt(prompt)
                            }
                    }
                }
            }
            .onChange(of: proxy.size.width, initial: true) { _, newValue in
                columns = Array(repeating: .init(.fixed(promptCardIdealWidth), alignment: .top),
                                count: Int(newValue / promptCardIdealWidth))
            }
        }
        .animation(.smooth, value: columns.count)
    }
    
    @ViewBuilder
    func MessageList() -> some View {
        VStack(alignment: .leading) {
            ForEach(chat?.orderedMessages ?? []) { message in
                MessageView(message: message).id(message.id)
            }
            if chatStatus == .userWaitingForResponse {
                UserWaitingForResponseView()
            }
        }
        .padding()
    }
    
    @ViewBuilder
    func UserWaitingForResponseView() -> some View {
        VStack(alignment: .leading) {
            HStack(alignment: .center) {
                MessageRole.assistant.icon.resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 25)
                Text(MessageRole.assistant.localizedName)
                    .font(.headline)
            }
            
            ActivityIndicatorView(isVisible: .constant(true),
                                  type: .opacityDots())
            .frame(width: 30, height: 10)
        }
    }
    
    @ViewBuilder
    func MessageInput() -> some View {
        VStack(alignment: .leading) {
            ScrollView(.horizontal) {
                HStack(alignment: .center) {
                    ForEach(draft.images, id: \.self) { data in
                        if let image = PlatformImage(data: data) {
                            Image(data: data)?.resizable()
                                .allowedDynamicRange(.high)
                                .interpolation(.none)
                                .aspectRatio(image.aspectRatio, contentMode: .fit)
                                .frame(height: 50)
                        }
                    }
                }
            }
            
            HStack(alignment: .center) {
                Button {
                    fileImporterPresented = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                
                TextField("Message", text: $draft.content).textFieldStyle(.plain)
                    .onSubmit {
#if canImport(AppKit)
                        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                            draft.content += "\n"
                        } else {
                            submitDraft()
                        }
#else
                        submitDraft()
#endif
                    }
                if chatStatus != .assistantWaitingForRequest {
                    Button(action: stopGenerateMessage, label: {Image(systemName: "stop.circle")})
                } else {
                    Button(action: submitDraft, label: {Image(systemName: "arrow.up.square")})
                        .disabled(draft.content.isEmpty)
                }
            }
            .padding(10)
            .overlay(
              RoundedRectangle()
                .stroke(.primary, lineWidth: 1)
            )
        }
        .imageScale(.large)
        .buttonStyle(.borderless)
        .safeAreaPadding()
        .background(.ultraThinMaterial)
    }
}

extension ChatView {
    
    func fetchLocalModels() {
        Task { do {
            models = try await OllamaClient.shared.models().models
            selectedModel = models.first
            } catch {
                debugPrint(error.localizedDescription)
            }
        }
    }
    
    func uploadImages(_ urls: [URL]) {
        for url in urls { do {
            let data = try Data(contentsOf: url)
            DispatchQueue.main.async {
                self.draft.images.append(data)
            } } catch {
                print("uploadImages error, \(error.localizedDescription)")
            }
        }
    }
    
    func submitPrompt(_ prompt: Prompt) {
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
        guard case .assistantWaitingForRequest = chatStatus,
              let model = selectedModel else { return }
        if self.chat == nil {
            self.chat = Chat()
            modelContext.persist(chat!)
        }
        guard let chat = self.chat else { return }
        DispatchQueue.main.async {
            chat.messages.append(message)
            self.resetDraft()
        }
        message.chat = chat
        modelContext.persist(message)
        let messages = chat.messages.compactMap{ toChatRequestMessage($0) }
        let request = ChatRequest(model: model.name,
                                  messages: messages)
        chatStatus = .userWaitingForResponse
        OllamaClient.shared.chat(request)
            .sink { completion in
                switch completion {
                case .finished: self.resetChat()
                case .failure(let error): print(error.localizedDescription)
                }
            } receiveValue: { response in
                if case .userWaitingForResponse = chatStatus {
                    DispatchQueue.main.async {
                        chat.messages.append(Message(role: .assistant))
                        self.chatStatus = .assistantResponding
                    }
                }
                guard case .assistantResponding = chatStatus else { return }
                if let message = response.message {
                    chat.messages.last?.content.append(message.content)
                }
            }
            .store(in: &cancellables)
    }
    
    func stopGenerateMessage() {
        resetChat()
        cancellables.forEach { cancellable in
            cancellable.cancel()
        }
    }
    
    func resetDraft() {
        draft = Message()
    }
    
    func resetChat() {
        chatStatus = .assistantWaitingForRequest
    }
    
    func toChatRequestMessage(_ message: Message) -> ChatRequest.Message {
        let images = message.images.compactMap { data in
            data.base64EncodedString()
        }
        let modelShouldKnow = UserDefaults.standard.value(forKey: UserDefaults.modelShouldKnow,
                                                          default: "")
        let modelShouldRespond = UserDefaults.standard.value(forKey: UserDefaults.modelShouldRespond,
                                                          default: "")
        var role: ChatRequest.Message.Role {
            switch message.role {
            case .user: .user
            case .assistant: .assistant
            case .system: .system
            }
        }
        return ChatRequest.Message(role: role,
                                   content: "\(modelShouldKnow)\n\(message.content)\n\(modelShouldRespond)",
                                   images: images)
    }
    
    func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let lastID = chat?.orderedMessages.last?.id else { return }
        withAnimation {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}

#Preview {
    ChatView(chat: .constant(Chat()))
}
