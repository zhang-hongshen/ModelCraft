//
//  MessageView.swift
//  ModelCraft
//
//  Created by Hongshen on 2/24/25.
//

import SwiftUI
import MapKit

import SwiftStreamingMarkdown

struct MessageView: View {
    
    @Bindable var message: Message
    var showsAssistantButtons = true
    
    @State private var isHovering = false
    @State private var isEditing = false
    
    @Environment(GlobalStore.self) private var globalStore
    @Environment(ChatService.self) private var service
    
    private static let columns = Array.init(repeating: GridItem(.flexible()), count: 4)
    
    var body: some View {
        VStack {
            switch message.role {
            case .user:
                UserMessageView()
            case .assistant:
                AssistantMessageView()
            case .tool:
                AssistantMessageView()
            default:
                EmptyView()
            }
        }
        .contentShape(Rectangle())
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
    func GenerationInfoButton(_ message: Message) -> some View {
        if let prefillTime = message.prefillTime,
           let tokensPerSecond = message.tokensPerSecond {
            GenerationMetricsButton(
                prefillTime: prefillTime,
                tokensPerSecond: tokensPerSecond
            )
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
        MarkdownView(text: message.content, config: .modelCraft)
            .multilineTextAlignment(.leading)
    }
    
}


// MARK: Assistant Message

extension MessageView {
    
    @ViewBuilder
    func AssistantMessageView() -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading) {
                
                if message.isWaitingForFirstToken {
                    ProgressView().controlSize(.small)
                } else {
                    MessageFilesView(message.files)
                    if showsAssistantButtons {
                        AssistantMessageContentView(message)
                            .contextMenu {
                                AssistantButtons()
                            }
                    } else {
                        AssistantMessageContentView(message)
                    }
                    if showsAssistantButtons {
                        AssistantButtons()
                            .buttonStyle(.borderless)
                            .opacity(isHovering ? 1 : 0)
                    }
                }
            }
            Spacer()
        }
    }
    
    @ViewBuilder
    func AssistantButtons() -> some View {
        HStack(alignment: .center) {
            CommonButtons(message)
            GenerationInfoButton(message)
            
            AssistantSpeechButton(content: message.content)
            
            Button {
                regenerateAssistantMessage()
            } label: {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
            }

        }
    }
    
    func AssistantMessageContentView(_ message: Message) -> some View {
        VStack(alignment: .leading) {

            if case .assistant = message.role, !message.content.isEmpty {
                MarkdownView(
                    text: message.content,
                    config: .modelCraft
                )
                .multilineTextAlignment(.leading)
            }
            
            
            if let toolCall = message.toolCall {
                if toolCall.function.name == ToolNames.textToImage {
                    ImageGenerationToolRenderer(
                        toolCall: toolCall,
                        result: message.toolCallResult,
                        status: message.toolCallStatus
                    )
                } else {
                    ToolCallView(toolCall: toolCall,
                                 result: message.toolCallResult,
                                 status: message.toolCallStatus)
                }
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

struct AssistantTurnView: View {

    let turn: AssistantTurn

    private var generationInfo: (prefillTime: TimeInterval, tokensPerSecond: Double)? {
        turn.messages.reversed().compactMap { message in
            guard case .assistant = message.role,
                  let prefillTime = message.prefillTime,
                  let tokensPerSecond = message.tokensPerSecond else {
                return nil
            }
            return (prefillTime, tokensPerSecond)
        }.first
    }

    @State private var isHovering = false

    @Environment(GlobalStore.self) private var globalStore
    @Environment(ChatService.self) private var service

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(turn.contentItems) { item in
                    switch item {
                    case .message(let message):
                        MessageView(message: message, showsAssistantButtons: false)
                    case .toolCallGroup(let messages):
                        ToolCallGroupView(messages: messages)
                    }
                }

                if !turn.isWaitingForFirstToken {
                    AssistantButtons()
                        .buttonStyle(.borderless)
                        .opacity(isHovering ? 1 : 0)
                }
            }
            .contextMenu {
                if !turn.isWaitingForFirstToken {
                    AssistantButtons()
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private func AssistantButtons() -> some View {
        HStack(alignment: .center) {
            CopyButton(style: .iconOnly) {
                Pasteboard.general.setString(turn.content)
            }

            if let info = generationInfo {
                GenerationMetricsButton(
                    prefillTime: info.prefillTime,
                    tokensPerSecond: info.tokensPerSecond
                )
            }

            AssistantSpeechButton(content: turn.content)

            Button {
                regenerateAssistantTurn()
            } label: {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
            }
            .disabled(turn.userMessage == nil)
        }
    }

    private func regenerateAssistantTurn() {
        guard let userMessage = turn.userMessage,
              let chat = userMessage.chat,
              let model = globalStore.selectedModel else {
            return
        }
        Task {
            try await service.resendMessage(
                model: model,
                chat: chat,
                message: userMessage
            )
        }
    }
}

private struct GenerationMetricsButton: View {

    let prefillTime: TimeInterval
    let tokensPerSecond: Double

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
        }
        .help("Generation Info")
        .popover(isPresented: $isPresented) {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("Prefill Time")
                    Text("\(prefillTime.formatted(.number.precision(.fractionLength(2))))s")
                        .monospacedDigit()
                }
                GridRow {
                    Text("Speed")
                    Text("\(tokensPerSecond.formatted(.number.precision(.fractionLength(2)))) tokens/s")
                        .monospacedDigit()
                }
            }
            .padding()
        }
    }
}

private struct AssistantSpeechButton: View {

    let content: String

    @Environment(SpeechManager.self) private var speechManager
    @Environment(UserSettings.self) private var userSettings

    var body: some View {
        if speechManager.isSpeaking {
            Button {
                speechManager.stop()
            } label: {
                Image(systemName: "stop.circle")
            }
        } else {
            Button {
                speechManager.speak(
                    content,
                    rate: Float(userSettings.speakingRate),
                    volume: Float(userSettings.speakingVolume)
                )
            } label: {
                Image(systemName: "speaker.wave.2")
            }
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
