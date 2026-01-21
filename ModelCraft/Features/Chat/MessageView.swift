//
//  MessageView.swift
//  ModelCraft
//
//  Created by Hongshen on 2/24/25.
//

import SwiftUI
import AVFoundation
import NaturalLanguage
import Combine

import MarkdownUI
import Splash
import ActivityIndicatorView

struct MessageView: View {
    
    @Bindable var message: Message
    
    @State private var copied = false
    @State private var infoPresented = false
    @State private var isHovering = false
    @State private var isEditing = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(SpeechManager.self) private var speechManager
    @Environment(GlobalStore.self) private var globalStore
    @Environment(UserSettings.self) private var userSettings
    @Environment(ChatService.self) private var service
    
    private let imageHeight: CGFloat = 200
    private let columns = Array.init(repeating: GridItem(.flexible()), count: 4)
    
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
            if message.role == .user {
                UserMessageView()
            } else {
                AssistantMessageView()
            }
        }
    }

}

// MARK: Common Message

extension MessageView {
    
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

extension MessageView {
    
    @ViewBuilder
    func UserMessageView() -> some View {
        HStack(alignment: .top) {
            Spacer()
            VStack(alignment: .trailing) {
                if !message.images.isEmpty {
                    MessageImageView(message)
                }
                
                if isEditing {
                    ChatInputView()
                } else {
                    if !message.content.isEmpty {
                        UserMessageContentView(message)
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
    func ChatInputView() -> some View {
        VStack(alignment: .trailing) {
            TextEditor(text: $message.content)
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
                    .disabled(message.chat?.status == .assistantResponding)
            }
            .buttonStyle(.borderless)
            .imageScale(.large)
        }
        .padding()
        .background {
            RoundedRectangle().fill(.quaternary).stroke(.primary, lineWidth: 1)
        }
    }
    
    @ViewBuilder
    func UserButtons() -> some View {
        HStack {
            CommonButtons(message)
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

extension MessageView {
    
    @ViewBuilder
    func AssistantMessageView() -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading) {
                
                ActivityIndicatorView(isVisible: Binding(
                    get: {message.status == .new},
                    set: { _ in }),
                                      type: .opacityDots())
                .frame(width: 30, height: 10)
                
                if !message.content.isEmpty {
                    AssistantMessageContentView(message)
                        .contextMenu {
                            AssistantButtons()
                        }
                }
                
                if !message.images.isEmpty {
                    MessageImageView(message)
                }
                
                if message.status != .new {
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
            CommonButtons(message)
            
            if speechManager.isSpeaking {
                Button {
                    speechManager.stop()
                } label: {
                    Image(systemName: "stop.circle")
                }
            } else {
                Button {
                    speechManager.speak(message.content,
                                            rate: Float(userSettings.speakingRate),
                                            volume: Float(userSettings.speakingVolume))
                } label: {
                    Image(systemName: "speaker.wave.2")
                }
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
                    if let totalDuration = message.totalDuration {
                        LabeledContent("Total cost:",
                                       value: Duration.nanoseconds(totalDuration).formatted(.units(allowed: [.seconds])))
                    }
                    if let loadDuration = message.loadDuration {
                        LabeledContent("Loading model cost:",
                                       value: Duration.nanoseconds(loadDuration).formatted(.units(allowed: [.seconds])))
                    }
                    if let promptEvalDuration = message.promptEvalDuration {
                        LabeledContent("Evaluating prompt cost:",
                                       value: Duration.nanoseconds(promptEvalDuration).formatted(.units(allowed: [.seconds])))
                    }
                    if let evalDurationInSecond = message.evalDurationInSecond {
                        LabeledContent("Generating response cost:",
                                       value: Duration.seconds(evalDurationInSecond).formatted(.units(allowed: [.seconds])))
                    }
                    if let tokenPerSecond = message.tokenPerSecond {
                        LabeledContent("Token per second:",
                                       value: "\(tokenPerSecond.formatted(.number.precision(.fractionLength(2))))/s")
                    }
                }.padding()
            }
        }
    }
    
    private struct Step: Identifiable {
        let id = UUID()
        var thought: String = ""
        var action: String? = nil
    }
    
    func AssistantMessageContentView(_ message: Message) -> some View {
        
        let parser = TagStreamParser()
        var steps: [Step] = []
        var answer = ""
        for event in parser.feed(message.content) {
            guard case .tag(let name, let content) = event else { continue }
            switch name {
            case "thought":
                if steps.isEmpty || steps.last?.action != nil {
                    steps.append(Step(thought: content))
                } else {
                    steps[steps.count - 1].thought += content
                }
            case "action":
                if steps.isEmpty {
                        steps.append(Step(action: content))
                    } else {
                        let lastIdx = steps.count - 1
                        steps[lastIdx].action = (steps[lastIdx].action ?? "") + content
                    }
            case "answer":
                answer += content
            default: break
            }
        }
        return VStack(alignment: .leading) {
            ForEach(steps) { step in
                VStack(alignment: .leading) {
                    if !step.thought.isEmpty {
                        ThoughtView(thought: step.thought)
                    }
                    if let action = step.action, let toolCall = ToolCall(json: action) {
                        Label(toolCall.localizedName, systemImage: toolCall.icon)
                            .padding(Layout.padding)
                            .background(.quaternary)
                            .cornerRadius()
                    }
                }
            }
            Markdown(message.status != .failed ? answer : "Please try again later.")
                .markdownTheme(.modelCraft)
                .markdownCodeSyntaxHighlighter(.splash(theme: self.splashTheme))
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .contextMenu {
                    Button {
                        
                    } label: {
                        Text("Ask")
                    }
                }
            
        }
        
    }
}

extension MessageView {
    
    func submitMessage() {
        guard let chat = message.chat,
                case .assistantWaitingForRequest = chat.status else { return }
        guard let model = globalStore.selectedModel else {
            globalStore.errorWrapper = ErrorWrapper(error: AppError.noSelectedModel)
            return
        }
        Task {
            try await service.resendMessage(
                model: model,
                knowledgeBase: globalStore.selectedKnowledgeBase,
                chat: chat,
                message: message)
        }
        
    }
}

import SwiftData
#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Chat.self, Message.self, configurations: config)
    let chat = Chat()
    let message = Message(role: .assistant, chat: chat, content:
        """
        <thought>First...</thought>
        <action>{"tool": "write_to_file", "parameters": {"path": "1.txt", "content": "test"}}</action>
        <thought>Next,...</thought>
        <action>{"tool": "execute_command", "parameters": {"command": "ls"}}</action>
        """)
    MessageView(message: message)
        .modelContainer(container)
        .environment(SpeechManager())
        .environment(GlobalStore())
        .environment(UserSettings())
        .environment(ChatService(container: container))
}
