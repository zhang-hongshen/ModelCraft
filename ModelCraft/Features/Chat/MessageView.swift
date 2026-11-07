//
//  MessageView.swift
//  ModelCraft
//
//  Created by Hongshen on 26/3/24.
//

import SwiftUI
import MapKit

import SwiftStreamingMarkdown

struct MessageView: View {
    
    @Bindable var message: Message
    var showsAssistantButtons = true
    var onRewind: ((Message) -> Void)?
    
    @State private var isHovering = false
    
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
            Pasteboard.setString(message.content)
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
                if !message.content.isEmpty {
                    UserMessageContentView(message)
                        .padding()
                        .background {
                            RoundedRectangle().fill(.userBubble)
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
    
    @ViewBuilder
    func UserButtons() -> some View {
        HStack {
            CommonButtons(message)
            Button {
                onRewind?(message)
            } label: {
                Label("Rewind", systemImage: "backward.end")
            }
            .labelStyle(.iconOnly)
            .help("Rewind")
            .disabled(onRewind == nil || service.isCompacting)

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

                MessageFilesView(message.files)
                if showsAssistantButtons {
                    AssistantMessageContentView(message)
                        .contextMenu {
                            AssistantButtons()
                        }
                } else {
                    AssistantMessageContentView(message)
                }
                if message.status == .new {
                    ProgressView()
                        .controlSize(.small)
                }
                if showsAssistantButtons {
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
                AssistantContentView(message: message)
            }
            
            
            if let toolCall = message.toolCall {
                if toolCall.function.name == ToolNames.textToImage {
                    ImageGenerationToolRenderer(
                        toolCall: toolCall,
                        result: message.toolCallResult,
                        status: message.toolCallStatus,
                        progress: message.imageGenerationProgress
                    )
                } else {
                    ToolCallView(toolCall: toolCall,
                                 result: message.toolCallResult,
                                 status: message.toolCallStatus,
                                 imageProgress: message.imageGenerationProgress,
                                 videoProgress: message.videoGenerationProgress)
                }
            }
        }
        
    }
        
}

extension MessageView {
    
    func regenerateAssistantMessage() {
        guard let chat = message.chat, let model = globalStore.selectedModel else { return }
        let messages = chat.conversation
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

/// Assistant text rendered as Markdown, with leading reasoning collapsed and `ui` blocks
/// rendered as native components.
private struct AssistantContentView: View {

    let message: Message

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(GlobalStore.self) private var globalStore
    @Environment(ChatService.self) private var service

    var body: some View {
        let segments = MessageContentSegment.segments(
            of: message.content,
            isComplete: message.status != .generating)
        VStack(alignment: .leading) {
            ForEach(segments) { segment in
                switch segment {
                case .thinking(let text, let isFinished):
                    ThinkingView(text: text, isFinished: isFinished)
                case .markdown(_, let text):
                    MarkdownView(
                        text: text,
                        config: message.status == .generating && !reduceMotion
                            ? .modelCraftStreaming : .modelCraft)
                        .multilineTextAlignment(.leading)
                case .ui(_, let source?):
                    GenerativeUIView(
                        source: source,
                        send: message.status == .generating ? nil : send)
                case .ui(_, nil):
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    /// Sends an action from a `ui` block as the user's next message in this chat.
    private func send(_ text: String) {
        guard let chat = message.chat,
              let model = globalStore.selectedModel,
              !service.isCompacting
        else { return }
        let userMessage = Message(role: .user, chat: chat, content: text)
        Task {
            try await service.sendMessage(model: model, chat: chat, message: userMessage)
        }
    }
}

private struct ThinkingView: View {

    let text: String
    let isFinished: Bool

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Text(isFinished ? LocalizedStringKey("Thought") : LocalizedStringKey("Thinking…"))
        }
        .foregroundStyle(.secondary)
    }
}

struct AssistantTurnView: View {

    let turn: AssistantTurn

    @State private var isHovering = false

    @Environment(GlobalStore.self) private var globalStore
    @Environment(ChatService.self) private var service

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(turn.contentItems) { item in
                    switch item {
                    case .message(let message):
                        MessageView(message: message, showsAssistantButtons: false)
                    case .toolCallGroup(let messages):
                        ToolCallGroupView(messages: messages)
                    }
                }

                if !turn.isWaitingForModelResponse {
                    AssistantButtons()
                        .buttonStyle(.borderless)
                        .opacity(isHovering ? 1 : 0)
                }
            }
            .contextMenu {
                if !turn.isWaitingForModelResponse {
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
                Pasteboard.setString(turn.content)
            }

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
            }
            .padding()
        }
    }
}

#if DEBUG
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
#endif
