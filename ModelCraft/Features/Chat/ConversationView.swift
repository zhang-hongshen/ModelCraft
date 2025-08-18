//
//  ConversationView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 2/24/25.
//

import SwiftUI
import AVFoundation
import NaturalLanguage
import Combine

import MarkdownUI
import Splash
import ActivityIndicatorView

struct ConversationView: View {
    
    @Bindable var conversation: Conversation
    @Binding var chatStatus: ChatStatus
    
    @State private var cancellables = Set<AnyCancellable>()
    @State private var copied = false
    @State private var infoPresented = false
    @State private var isHovering = false
    @State private var isEditing = false
    @State private var thinkingExpanded = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.speechSynthesizer) private var speechSynthesizer
    @EnvironmentObject private var globalStore: GlobalStore
    @EnvironmentObject private var userSettings: UserSettings
    
    private let imageHeight: CGFloat = 200
    private let columns = Array.init(repeating: GridItem(.flexible()), count: 4)
    
    private var userMessage: Message {
        get {
            conversation.userMessage
        }
        set {
            conversation.userMessage = newValue
        }
    }
    
    private var assistantMessage: Message {
        get {
            conversation.assistantMessage
        }
        set {
            conversation.assistantMessage = newValue
        }
    }
    
    private var splashTheme: Splash.Theme {
        switch self.colorScheme {
        case .dark:
            return .sundellsColors(withFont: .init(size: 16))
        default:
            return .sunset(withFont: .init(size: 16))
        }
    }
    
    var body: some View {
        VStack {
            UserMessageView()
            AssistantMessageView()
        }
    }

}

// MARK: Common Message

extension ConversationView {
    
    @ViewBuilder
    func CommonButtons(_ message: Message) -> some View {
        CopyButton(style: .iconOnly) {
            Pasteboard.general.setString(message.content)
        }
    }
    
    @ViewBuilder
    func MessageImageView(_ message: Message) -> some View {
        LazyVGrid(columns: columns){
            ForEach(message.images, id: \.self) { data in
                ImageLoader(data: data, contentMode: .fit)
                    .frame(height: imageHeight)
                    .cornerRadius()
            }
        }
    }

}

// MARK: User Message

extension ConversationView {
    
    @ViewBuilder
    func UserMessageView() -> some View {
        HStack(alignment: .top) {
            Spacer()
            VStack(alignment: .trailing) {
                if !userMessage.images.isEmpty {
                    MessageImageView(userMessage)
                }
                
                if isEditing {
                    VStack(alignment: .trailing) {
                        TextEditor(text: $conversation.userMessage.content)
                            .textEditorStyle(.plain)
                            .font(.body)
                        HStack {
                            Button(role: .cancel) {
                                isEditing = false
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            Button {
                                submitMessage()
                                isEditing = false
                            } label: {
                                Image(systemName: "arrow.up.circle.fill")
                            }.tint(.accentColor)
                                .disabled(chatStatus == ChatStatus.assistantResponding)
                        }
                        .buttonStyle(.borderless)
                        .imageScale(.large)
                    }
                    .padding()
                    .background {
                        RoundedRectangle().fill(.quaternary).stroke(.primary, lineWidth: 1)
                    }
                } else {
                    if !userMessage.content.isEmpty {
                        UserMessageContentView(userMessage)
                            .padding()
                            .background {
                                RoundedRectangle().fill(.quaternary)
                            }
                            .contextMenu {
                                UserButtons()
                            }
                                
                    }
                    UserButtons()
                        .buttonStyle(.borderless)
                        .opacity(isHovering ? 1 : 0)
                }
                
            }
            .onHover(perform: { isHovering = $0 })
        }
    }
    
    @ViewBuilder
    func UserButtons() -> some View {
        HStack {
            CommonButtons(userMessage)
            Button {
                isEditing = true
            } label: {
                Image(systemName: "square.and.pencil")
            }

        }
    }
    
    @ViewBuilder
    func UserMessageContentView(_ message: Message) -> some View {
        Markdown(message.status != .failed ? message.content : "Failed.Please try again later.")
            .markdownTheme(.modelCraft)
            .markdownCodeSyntaxHighlighter(.splash(theme: self.splashTheme))
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
    }
    
}


// MARK: Assistant Message

extension ConversationView {
    
    @ViewBuilder
    func AssistantMessageView() -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading) {
                
                ActivityIndicatorView(isVisible: Binding(
                    get: {assistantMessage.status == .new},
                    set: { _ in }),
                                      type: .opacityDots())
                .frame(width: 30, height: 10)
                
                if !assistantMessage.content.isEmpty {
                    AssistantMessageContentView(assistantMessage)
                        .contextMenu {
                            AssistantButtons()
                        }
                }
                
                if !assistantMessage.images.isEmpty {
                    MessageImageView(assistantMessage)
                }
                
                if assistantMessage.status != .new {
                    AssistantButtons()
                        .buttonStyle(.borderless)
                        .opacity(isHovering ? 1 : 0)
                }
            }
            .onHover(perform: { isHovering = $0 })
            Spacer()
        }
    }
    
    @ViewBuilder
    func AssistantButtons() -> some View {
        HStack(alignment: .center) {
            CommonButtons(assistantMessage)
            
            if speechSynthesizer.isSpeaking {
                Button {
                    speechSynthesizer.stop()
                } label: {
                    Image(systemName: "stop.circle")
                }
            } else {
                Button {
                    speechSynthesizer.speak(assistantMessage.content,
                                            rate: Float(userSettings.speakingRate),
                                            volume: Float(userSettings.speakingVolume))
                } label: {
                    Image(systemName: "speaker.wave.2")
                }.disabled(speechSynthesizer.isSpeaking)
            }
            
            Button {
                submitMessage()
            } label: {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
            }

            Button {
                infoPresented = true
            } label: {
                Image(systemName: "info.circle")
            }.popover(isPresented: Binding(
                get: { infoPresented && isHovering },
                set: { infoPresented = $0 }
            ), arrowEdge: .top) {
                Form {
                    if let totalDuration = assistantMessage.totalDuration {
                        LabeledContent("Total cost:",
                                       value: Duration.nanoseconds(totalDuration).formatted(.units(allowed: [.seconds])))
                    }
                    if let loadDuration = assistantMessage.loadDuration {
                        LabeledContent("Loading model cost:",
                                       value: Duration.nanoseconds(loadDuration).formatted(.units(allowed: [.seconds])))
                    }
                    if let promptEvalDuration = assistantMessage.promptEvalDuration {
                        LabeledContent("Evaluating prompt cost:",
                                       value: Duration.nanoseconds(promptEvalDuration).formatted(.units(allowed: [.seconds])))
                    }
                    if let evalDurationInSecond = assistantMessage.evalDurationInSecond {
                        LabeledContent("Generating response cost:",
                                       value: Duration.seconds(evalDurationInSecond).formatted(.units(allowed: [.seconds])))
                    }
                    if let tokenPerSecond = assistantMessage.tokenPerSecond {
                        LabeledContent("Token per second:",
                                       value: "\(tokenPerSecond.formatted(.number.precision(.fractionLength(2))))/s")
                    }
                }.padding()
            }
        }
    }
    
    func AssistantMessageContentView(_ message: Message) -> some View {
        let parser = TagStreamParser()
        let events = parser.feed(assistantMessage.content)
        var answer = ""
        var think = ""
        for e in events {
            switch e {
            case .think(let t): think += t; break;
            case .answer(let t): answer += t; break;
            default: break
            }
        }
        return VStack(alignment: .leading) {
            if !think.isEmpty {
                DisclosureGroup("Thinking", isExpanded: $thinkingExpanded) {
                    Text(think)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Markdown(message.status != .failed ? answer : "Please try again later.")
                .markdownTheme(.modelCraft)
                .markdownCodeSyntaxHighlighter(.splash(theme: self.splashTheme))
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
        }
        
    }
}

extension ConversationView {
    
    func submitMessage() {
        
        guard case .assistantWaitingForRequest = chatStatus else { return }
        guard let model = globalStore.selectedModel else {
            globalStore.errorWrapper = ErrorWrapper(error: AppError.noSelectedModel)
            return
        }
        Task {
            DispatchQueue.main.async {
                assistantMessage.status = .new
                assistantMessage.content = ""
                chatStatus = .userWaitingForResponse
            }
            var context = ""
            if let knowledgeBase = globalStore.selectedKnowledgeBase {
                context = await knowledgeBase.search(userMessage.content).joined(separator: " ")
            }
            
            let messages = conversation.chat.allMessages(before: conversation)
            + [AgentPrompt.answerQuestion(context: context, question: userMessage.content)]
            
            OllamaService.shared.chat(model: model, messages: messages.compactMap{ OllamaService.toChatRequestMessage($0) })
                .sink { completion in
                    DispatchQueue.main.async {
                        switch completion {
                        case .finished:
                            assistantMessage.status = .generated
                        case .failure(let error):
                            assistantMessage.status = .failed
                        }
                        chatStatus = .assistantWaitingForRequest
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
                            chatStatus = .assistantWaitingForRequest
                            assistantMessage.evalCount = response.evalCount
                            assistantMessage.evalDuration = response.evalDuration
                            assistantMessage.loadDuration = response.loadDuration
                            assistantMessage.promptEvalCount = response.promptEvalCount
                            assistantMessage.promptEvalDuration = response.promptEvalDuration
                            assistantMessage.totalDuration = response.totalDuration
                            assistantMessage.status = .generated
                        }
                    }
                }.store(in: &cancellables)
        }
        
    }
}

#Preview {
    let userMessage = Message(role: .user, content: "Hello")
    let assistantMessage = Message(role: .assistant, content: "Hello, I'm ModelCraft.")
    let conversation = Conversation(chat: Chat(),
                                    userMessage: userMessage,
                                    assistantMessage: assistantMessage)
    ConversationView(conversation: conversation,
                     chatStatus: .constant(.assistantResponding))
}
