//
//  ChatView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 23/3/2024.
//

import SwiftUI
import Combine
import CoreSpotlight
import TipKit

import OllamaKit
import ActivityIndicatorView

struct SelectModelTip: Tip {
    
    @Parameter
    static var presented: Bool = false
    
    var title: Text {
        Text("Choose a model to chat")
    }
    
    var rules: [Rule] {
        [
            #Rule(Self.$presented) {
                $0 == true
            },
        ]
    }
}

struct ChatView: View {
    
    @Binding var chat: Chat?
    
    @State private var draft = Message(role: .user)
    @State private var assistantMessage = Message(role: .assistant)
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
    private let selectModelTip = SelectModelTip()
    private let openStoreTip = OpenStoreTip()
    
    @Environment(\.modelContext) private var modelContext
    @Environment(\.serverStatus) private var serverStatus
    @Environment(\.downaloadedModels) private var models
    @Environment(\.selectedModel) private var selectedModel
    
    var body: some View {
        MainView()
        .frame(minHeight: 250)
        .toolbar(content: ToolbarItems)
        .safeAreaInset(edge: .bottom, content: MessageInput)
        .onDrop(of: [.image], isTargeted: nil) { providers in
            for provider in providers {
                let progress = provider.loadDataRepresentation(for: .image) { dataOrNil, errorOrNil in
                    guard let data = dataOrNil else { return }
                    DispatchQueue.main.async {
                        draft.images.append(data)
                    }
                }
                print("progress: \(progress.fractionCompleted)%, total: \(progress.totalUnitCount)")
            }
            return true
        }
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
        // write an spotlight user search handler
        .userActivity("com.hanson.ModelCraft.chat") { userActivity in
            userActivity.isEligibleForSearch = true
            userActivity.title = "Ice Cream"
            
            print("userActivity: ")
        }
        .onContinueUserActivity("com.hanson.ModelCraft.chat") { userActivity in
            guard let searchString = userActivity.userInfo?[CSSearchQueryString] as? String else {
              return
            }
            print("onContinueUserActivity, \(searchString)")
            chat = Chat(messages: [])
            self.draft.content = searchString
            submitMessage(Message(role: .user, content: searchString))
        }
    }
}

extension ChatView {
    
    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            
            if models.isEmpty {
                Text("No Available Model")
            } else {
                Picker("Models", selection: selectedModel) {
                    ForEach(models, id: \.name) { model in
                        Text(verbatim: model.name).tag(model as ModelInfo?)
                    }
                }
                .popoverTip(selectModelTip, arrowEdge: .bottom)
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
                VStack(alignment: .center) {
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
                .safeAreaPadding(.horizontal)
            }
            .frame(minWidth: promptCardIdealWidth)
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
                                .frame(height: 40)
                                .cornerRadius()
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
                    Button(action: stopGenerateMessage, label: {Image(systemName: "stop.circle.fill")})
                } else {
                    let submitDisabled = draft.content.isEmpty || selectedModel == nil
                    Button(action: submitDraft, label: {Image(systemName: "arrow.up.circle.fill")})
                        .tint(submitDisabled ? .secondary : .accentColor)
                        .disabled(submitDisabled)
                }
            }
            .padding(Default.padding)
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
        
        guard case .assistantWaitingForRequest = chatStatus else { return }
        guard let model = selectedModel.wrappedValue else {
            SelectModelTip.presented = true
            return
        }
        if self.chat == nil {
            self.chat = Chat()
            modelContext.persist(chat!)
        }
        guard let chat = self.chat else { return }
        DispatchQueue.main.async {
            message.chat = chat
            chat.messages.append(message)
            modelContext.persist(message)
            self.clearDraft()
            chatStatus = .userWaitingForResponse
        }
        let modelShouldKnow = UserDefaults.standard.value(forKey: UserDefaults.modelShouldKnow,
                                                          default: "")
        let modelShouldRespond = UserDefaults.standard.value(forKey: UserDefaults.modelShouldRespond,
                                                          default: "")
        let messages = [Message(role: .system, content: "\(modelShouldKnow)\n\(modelShouldRespond)")] + chat.messages
        OllamaService.shared.chat(model: model.name, messages: messages)
            .sink { completion in
                switch completion {
                case .finished: self.resetChat()
                case .failure(let error): print("error, \(error.localizedDescription)")
                }
            } receiveValue: { response in
                if case .userWaitingForResponse = chatStatus {
                    DispatchQueue.main.async {
                        assistantMessage = Message(role: .assistant)
                        chat.messages.append(assistantMessage)
                        chatStatus = .assistantResponding
                    }
                }
                guard case .assistantResponding = chatStatus else { return }
                print("error \(response)")
                if let message = response.message {
                    DispatchQueue.main.async {
                        assistantMessage.content.append(message.content)
                    }
                }
                if response.done {
                    resetChat()
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
    
    func clearDraft() {
        draft.content = ""
        draft.images = []
    }
    
    func resetChat() {
        chatStatus = .assistantWaitingForRequest
        clearDraft()
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
