//
//  MessageView.swift
//  ModelCraft
//
//  Created by Hongshen on 2/24/25.
//

import SwiftUI
import AVFoundation
import NaturalLanguage
import MapKit

import MarkdownUI
import Splash
import MLXLMCommon

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
    
    private static let columns = Array.init(repeating: GridItem(.flexible()), count: 4)
    
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
                default:
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
    func MessageAttachmentsView(_ attachments: [URL]) -> some View {
        LazyVGrid(columns: MessageView.columns){
            ForEach(attachments, id: \.self) { url in
                AttachmentContentView(url: url).frame(height: 70)
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
                MessageAttachmentsView(message.attachments)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                
                if isEditing {
                    ChatInputView(
                        userInput: $message,
                        trailing: {
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
                                }
                            }
                            .buttonStyle(.borderless)
                            .imageScale(.large)
                        })
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
                    ProgressView().progressViewStyle(.scaled)
                } else {
                    MessageAttachmentsView(message.attachments)
                    AssistantMessageContentView(message)
                        .contextMenu {
                            AssistantButtons()
                        }
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
    
//    func AssistantMessageContentView(_ message: Message) -> some View {
//        
//        var think = ""
//        var answer = ""
//        
//        for event in TagStreamParser().feed(message.content) {
//            if case .inTag(let tag, let content) = event {
//                
//                if tag == "think" {
//                    think.append(content)
//                } else if tag == "answer" {
//                    answer.append(content)
//                }
//            }
//        }
//        
//        return VStack(alignment: .leading) {
//            
//            if !think.isEmpty {
//                ThinkView(think)
//            }
//            
//            if !answer.isEmpty {
//                Markdown(answer)
//                    .markdownTheme(.modelCraft)
//                    .markdownCodeSyntaxHighlighter(.splash(theme: self.splashTheme))
//                    .textSelection(.enabled)
//                    .multilineTextAlignment(.leading)
//            }
//            
//            
//            if let toolCall = message.toolCall,
//                let toolCallResult = message.toolCallResult {
//                Button {
//                    inspectorPresented = true
//                    updateInspector(ToolCallView(toolCall: toolCall, toolCallResult: toolCallResult))
//                } label: {
//                    Label(toolCall.localizedName, systemImage: toolCall.icon)
//                }.foregroundStyle(.secondary)
//            }
//            
//        }
//        
//    }
    
    func AssistantMessageContentView(_ message: Message) -> some View {
        VStack(alignment: .leading) {

            Markdown(message.content)
                    .markdownTheme(.modelCraft)
                    .markdownCodeSyntaxHighlighter(.splash(theme: self.splashTheme))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
            
            
            if let toolCall = message.toolCall,
                let toolCallResult = message.toolCallResult {
                Button {
                    inspectorPresented = true
                    updateInspector(ToolCallView(toolCall: toolCall, toolCallResult: toolCallResult))
                } label: {
                    Label(toolCall.localizedName, systemImage: toolCall.icon)
                }.foregroundStyle(.secondary)
            }
        }
        
    }
        
}

extension MessageView {
    
    func submitMessage() {
        guard let chat = message.chat else { return }
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
        guard let chat = message.chat, let model = globalStore.selectedModel else { return }
        let messages = chat.sortedMessages
        guard let index = messages.firstIndex(of: message),
            let userMessage = messages[..<index].reversed().first(where: { $0.role == .user }) else {
            return
        }
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
        .environment(ChatService())
}
