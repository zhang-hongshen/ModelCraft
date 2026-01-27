//
//  MessageView.swift
//  ModelCraft
//
//  Created by Hongshen on 2/24/25.
//

import SwiftUI
import AVFoundation
import NaturalLanguage

import MarkdownUI
import Splash

struct MessageView: View {
    
    @Bindable var message: Message
    @Binding var inspectorPresented: Bool
    var updateInspector: (any View) -> Void
    
    @State private var copied = false
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
        ZStack {
            
            Color.clear.contentShape(Rectangle())
            
            VStack {
                switch message.role {
                case .user:
                    UserMessageView()
                case .assistant:
                    AssistantMessageView()
                case .system, .tool:
                    EmptyView()
                }
            }
        }
        .onHover(perform: { isHovering = $0 })
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
            
        }
    }
    
    @ViewBuilder
    func ChatInputView() -> some View {
        VStack(alignment: .trailing) {
            TextField("", text: $message.content, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
            
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
        Markdown(message.content)
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
                
                
                if message.status == .new {
                    ProgressView().controlSize(.small)
                }
                
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
                regenerateAssistantMessage()
            } label: {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
            }

        }
    }
    
    private struct Step: Identifiable {
        let id = UUID()
        var thought: String = ""
        var action: String? = nil
        var observation: String? = nil
    }
    
    func AssistantMessageContentView(_ message: Message) -> some View {
        
        let parser = TagStreamParser()
        var steps: [Step] = []
        var answer = ""
        for event in parser.feed(message.content) {
            guard case .inTag(let name, let content) = event else { continue }
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
            case "observation":
                if steps.isEmpty {
                    steps.append(Step(observation: content))
                } else {
                    let lastIdx = steps.count - 1
                    steps[lastIdx].observation = (steps[lastIdx].observation ?? "") + content
                }
            case "answer": answer += content
            default: break
            }
        }
        return VStack(alignment: .leading) {
            ForEach(steps) { step in
                VStack(alignment: .leading) {
                    if !step.thought.isEmpty {
                        ThoughtView(thought: step.thought)
                    }
                    if let action = step.action, let toolCall = ToolCall(json: action), let observation = step.observation {
                        HStack {
                            Button {
                                inspectorPresented = true
                                updateInspector(Text(step.observation ?? ""))
                            } label: {
                                Label(toolCall.localizedName, systemImage: toolCall.icon)
                            }
                            Text(observation)
                        }.foregroundStyle(.secondary)
                        
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
    
    func regenerateAssistantMessage() {
        guard let chat = message.chat else { return }
        guard let model = globalStore.selectedModel else {
            return
        }
        guard let index = chat.sortedMessages.firstIndex(of: message) else {
            return
        }
        guard index >= 1 else { return }
        let userMessage = chat.sortedMessages[index - 1]
        Task {
            try await service.resendMessage(model: model,
                                            knowledgeBase: globalStore.selectedKnowledgeBase,
                                            chat: chat,
                                            message: userMessage)
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
        <observation>...</observation>
        <thought>Next,...</thought>
        <action>{"tool": "execute_command", "parameters": {"command": "ls"}}</action>
                <observation>...</observation>
        <answer>answer</answer>
        """)
    MessageView(message: message,
                inspectorPresented: .constant(true)) { _ in }
        .modelContainer(container)
        .environment(SpeechManager())
        .environment(GlobalStore())
        .environment(UserSettings())
        .environment(ChatService(container: container))
}
