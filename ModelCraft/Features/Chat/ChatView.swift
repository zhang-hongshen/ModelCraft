//
//  ChatView.swift
//  ModelCraft
//
//  Created by Hongshen on 23/3/2024.
//

import SwiftUI
import SwiftData


struct ChatView: View {

    let chat: Chat?
    
    @Query(Project.fetch()) private var projects: [Project]
    
    @Query(ModelTask.fetchUnCompletedDownloadTask)
    private var uncompletedDownloadTasks: [ModelTask] = []
    
    @State private var draft = Message(role: .user)
    @State private var voiceState: VoiceState = .idle
    @State private var composerHeight: CGFloat = 0
    
    enum VoiceState {
        case idle
        case loading
        case recording
    }
    
    @Environment(GlobalStore.self) private var globalStore
    @Environment(LocalModelStore.self) private var localModelStore
    @Environment(STTService.self) private var sttService
    
    @State private var chatService = ChatService()
    private static let minWidth: CGFloat = 270
    
    var body: some View {
        MainView()
            .frame(minWidth: ChatView.minWidth, minHeight: 250)
            .toolbar(content: ToolbarItems)
            .onChange(of: localModelStore.models, initial: true) { _, availableModels in
                guard globalStore.selectedModel == nil else { return }
                globalStore.selectedModel = availableModels.first
            }
            .modifier(AudioLevelChangeModifier { transcript in
                _ = submitMessage(content: transcript, files: [])
            })
    }
}

extension ChatView {
    
    @ViewBuilder
    func ModelPicker() -> some View {
        
        if localModelStore.models.isEmpty {
            Text("No Models Available").disabled(true)
        } else {
            ForEach(localModelStore.models) { model in
                Button {
                    globalStore.selectedModel = model
                } label: {
                    Text(model.displayName)
                    if globalStore.selectedModel == model {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
        ForEach(uncompletedDownloadTasks) { task in
            ModelTaskView(task: task).disabled(true)
        }
    }

    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Menu {
                ModelPicker()
            } label: {
                VStack(alignment: .leading) {
                    Text(globalStore.selectedModel?.displayName ?? String(localized: "Select Model"))
                        .font(.headline)

                }
            }
            .menuStyle(.button)
        }
        
        if let chat = chat {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    globalStore.currentTab = nil
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                
                Menu {
                    Menu("Move to project") {
                        ForEach(projects) { project in
                            Button(project.title) {
                                chat.project = project
                            }
                        }
                    }
                    DeleteButton(style: .iconAndText) {
                        chatService.deleteChat(chat)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                
            }
        }
        
    }
    
    @ViewBuilder
    func voiceModeButton() -> some View {
        let disabled = globalStore.selectedModel == nil
        Button {
            Task {
                switch voiceState {
                case .idle:
                    voiceState = .loading
                    await sttService.loadModel()
                    await sttService.startRecording()
                    voiceState = .recording
                case .recording:
                    sttService.stopRecording()
                    voiceState = .idle
                case .loading:
                    break
                }
            }
        } label: {
            switch voiceState {
            case .loading:
                ProgressView().controlSize(.small)
            case .recording:
                Image(systemName: "stop.fill")
            case .idle:
                Image(systemName: "waveform")
            }
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .disabled(disabled)
        .help("Voice Mode")
    }
    
    
    @ViewBuilder
    func StopGeneratingMessageButton() -> some View {
        Button {
            if let chat = chat {
                chatService.stopGenerating(chat: chat)
            }
        } label: {
            Image(systemName: "stop.fill")
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .controlSize(.large)
    }
    
    @ViewBuilder
    func SubmitMessageButton() -> some View {
        let disabled = globalStore.selectedModel == nil || draft.content.isEmpty
        Button(action: submitDraft) {
            Image(systemName: "arrow.up")
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .disabled(disabled)
        .keyboardShortcut(.return, modifiers: .command)
    }
    
    @ViewBuilder
    func MainView() -> some View {
        ZStack(alignment: .bottom) {
            if let chat = chat {
                let messages = chat.sortedMessages
                let items = ConversationContentBuilder.items(from: messages)
                let lastItemID = items.last?.id
                ScrollViewReader { proxy in
                    ScrollView {
                        ConversationItemsView(items: items)
                            .environment(chatService)
                            .safeAreaPadding()
                        
                        Text(sttService.transcript)
                            .padding()
                            .animation(.easeInOut, value: sttService.transcript)
                    }
                    .contentMargins(.leading, Layout.padding, for: .scrollContent)
                    .contentMargins(.bottom, composerHeight, for: .scrollContent)
                    .contentMargins(0, for: .scrollIndicators)
                    .onChange(of: messages.last) {
                        scrollToBottom(proxy, lastID: lastItemID)
                    }
                    .onAppear {
                        scrollToBottom(proxy, lastID: lastItemID)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollTargetBehavior(.paging)
            } else {
                Text("How can I help you today?")
                    .font(.title.bold())
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaPadding(.bottom, composerHeight)
            }

            Rectangle()
                .fill(.background)
                .mask(
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: composerHeight + 48)
                .allowsHitTesting(false)
            
            VStack(spacing: 8) {
                if let pendingDecision = chatService.decisionCoordinator.pendingDecision {
                    DecisionRequestView(
                        pendingDecision: pendingDecision,
                        onConfirm: chatService.decisionCoordinator.submit)
                    .id(pendingDecision.id)
                }

                ChatInputView(
                    userInput: draft,
                    trailing: {
                        HStack {
                            if let chat = chat, chat.isGenerating {
                                StopGeneratingMessageButton()
                            } else {
                                if draft.content.isEmpty {
                                    voiceModeButton()
                                } else {
                                    SubmitMessageButton()
                                }
                            }
                        }
                    }
                )
            }
            .shadow(color: Color.primary.opacity(0.1), radius: 8, x: 0, y: -4)
            .safeAreaPadding()
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { composerHeight in
                self.composerHeight = composerHeight
            }
        }
        
    }
    
}

extension ChatView {
    
    func submitMessage(content: String, files: [URL]) -> Bool {
        guard let model = globalStore.selectedModel else { return false }
        let activeChat: Chat
        if let chat = chat {
            activeChat = chat
        } else {
            activeChat = chatService.createChat()
            globalStore.currentTab = .chat(activeChat)
        }
        let message = Message(role: .user, chat: activeChat,
                              content: content, files: files)
        Task {
            try await chatService.sendMessage(
                model: model,
                chat: activeChat,
                message: message
            )
        }
        return true
    }

    func submitDraft() {
        if !submitMessage(content: draft.content, files: draft.files) {
            return
        }
        clearDraft()
    }
    
    func clearDraft() {
        draft.content = ""
        draft.files = []
    }
    
    func scrollToBottom(_ proxy: ScrollViewProxy, lastID: ConversationContentItem.ID?) {
        guard let lastID else { return }
        withAnimation {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}

private struct DecisionRequestView: View {

    let pendingDecision: DecisionCoordinator.PendingDecision
    let onConfirm: ([DecisionAnswer]) -> Void

    @State private var selectedOptionIDs: [String: String]
    @State private var customQuestionIDs: Set<String> = []
    @State private var customAnswers: [String: String] = [:]

    init(
        pendingDecision: DecisionCoordinator.PendingDecision,
        onConfirm: @escaping ([DecisionAnswer]) -> Void
    ) {
        self.pendingDecision = pendingDecision
        self.onConfirm = onConfirm
        let selections = pendingDecision.request.questions.reduce(into: [String: String]()) {
            selections, question in
            guard let recommendedOptionID = question.recommendedOptionID,
                  question.options.contains(where: { $0.id == recommendedOptionID }) else {
                return
            }
            selections[question.id] = recommendedOptionID
        }
        self._selectedOptionIDs = State(initialValue: selections)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(pendingDecision.request.questions) { question in
                        DecisionQuestionView(
                            question: question,
                            selectedOptionID: selectedOptionBinding(for: question.id),
                            isCustom: customBinding(for: question.id),
                            customAnswer: customAnswerBinding(for: question.id)
                        )
                    }
                }
            }
            .frame(maxHeight: 360)

            HStack {
                Spacer()
                Button("Confirm") {
                    onConfirm(answers)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isComplete)
            }
        }
        .padding()
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.separator.opacity(0.5))
        }
    }

    private var isComplete: Bool {
        pendingDecision.request.questions.allSatisfy { question in
            if customQuestionIDs.contains(question.id) {
                return !(customAnswers[question.id] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            }
            return selectedOptionIDs[question.id] != nil
        }
    }

    private var answers: [DecisionAnswer] {
        pendingDecision.request.questions.map { question in
            if customQuestionIDs.contains(question.id) {
                return DecisionAnswer(
                    questionID: question.id,
                    selectedOptionID: nil,
                    customAnswer: customAnswers[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return DecisionAnswer(
                questionID: question.id,
                selectedOptionID: selectedOptionIDs[question.id],
                customAnswer: nil)
        }
    }

    private func selectedOptionBinding(for questionID: String) -> Binding<String?> {
        Binding(
            get: { selectedOptionIDs[questionID] },
            set: { selectedOptionID in
                selectedOptionIDs[questionID] = selectedOptionID
            })
    }

    private func customBinding(for questionID: String) -> Binding<Bool> {
        Binding(
            get: { customQuestionIDs.contains(questionID) },
            set: { isCustom in
                if isCustom {
                    customQuestionIDs.insert(questionID)
                    selectedOptionIDs[questionID] = nil
                } else {
                    customQuestionIDs.remove(questionID)
                }
            })
    }

    private func customAnswerBinding(for questionID: String) -> Binding<String> {
        Binding(
            get: { customAnswers[questionID] ?? "" },
            set: { customAnswers[questionID] = $0 })
    }
}

private struct DecisionQuestionView: View {

    let question: DecisionQuestion
    @Binding var selectedOptionID: String?
    @Binding var isCustom: Bool
    @Binding var customAnswer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.question)
                .font(.headline)

            ForEach(question.options) { option in
                Button {
                    isCustom = false
                    selectedOptionID = option.id
                } label: {
                    DecisionOptionLabel(
                        option: option,
                        isSelected: !isCustom && selectedOptionID == option.id,
                        isRecommended: question.recommendedOptionID == option.id)
                }
                .buttonStyle(.plain)
            }

            Button {
                isCustom = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isCustom ? "largecircle.fill.circle" : "circle")
                    Text("Custom")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isCustom {
                TextField("Enter your answer", text: $customAnswer, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

private struct DecisionOptionLabel: View {

    let option: DecisionOption
    let isSelected: Bool
    let isRecommended: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(option.label)
                    if isRecommended {
                        Text("Recommended")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let description = option.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

private struct ConversationItemsView: View {

    let items: [ConversationContentItem]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                switch item {
                case .message(let message):
                    MessageView(message: message)
                        .scrollTargetLayout()
                case .assistantTurn(let turn):
                    AssistantTurnView(turn: turn)
                        .scrollTargetLayout()
                }
            }
        }
    }
}

private struct AudioLevelChangeModifier: ViewModifier {

    let onTranscription: (String) -> Void

    @Environment(STTService.self) private var sttService

    func body(content: Content) -> some View {
        content
            .onChange(of: sttService.audioLevel) { oldValue, newValue in
                if oldValue <= 0.1 && newValue > 0.1 {
                    Task {
                        await sttService.startRecording()
                    }
                }
                if oldValue > 0.1 && newValue <= 0.1 {
                    sttService.stopRecording()
                    onTranscription(sttService.transcript)
                }
            }
    }
}


#Preview(traits: .preview) {
    ChatView(chat: .preview)
        .frame(width: 760, height: 900)
}
