//
//  MessageView.swift
//  ModelCraft
//
//  Created by Hongshen on 2/24/25.
//

import SwiftUI
import MapKit

import MarkdownUI
import Splash

struct MessageView: View {
    
    @Bindable var message: Message
    
    @State var toolCallPresented: Bool = false
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
    func MessageFilesView(_ attachments: [URL]) -> some View {
        LazyVGrid(columns: MessageView.columns){
            ForEach(attachments, id: \.self) { url in
                MessageFileContentView(url: url).frame(height: 70)
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
                MessageFilesView(message.files)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                if isEditing {
                    ChatInputView(
                        userInput: message,
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
                                    Image(systemName: "arrow.up")
                                }.buttonBorderShape(.circle)
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
                    ProgressView().controlSize(.small)
                } else {
                    MessageFilesView(message.files)
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
    
    func AssistantMessageContentView(_ message: Message) -> some View {
        VStack(alignment: .leading) {

            Markdown(message.content)
                    .markdownTheme(.modelCraft)
                    .markdownCodeSyntaxHighlighter(.splash(theme: self.splashTheme))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
            
            
            if let toolCall = message.toolCall {
                ToolCallView(toolCall: toolCall,
                             result: message.toolCallResult,
                             status: message.toolCallStatus)
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
                                            chat: chat,
                                            message: userMessage)
        }
        
    }
}

#Preview(traits: .preview){
    ScrollView {
        VStack {
            ForEach(Message.previews) {
                MessageView(message: $0)
            }
        }
        .padding()
    }
}
