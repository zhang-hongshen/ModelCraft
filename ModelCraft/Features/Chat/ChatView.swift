//
//  ChatView.swift
//  ModelCraft
//
//  Created by Hongshen on 23/3/2024.
//

import SwiftUI
import SwiftData
import AppKit


struct ChatView: View {

    let chat: Chat?
    
    @Query(Project.fetch()) private var projects: [Project]
    
    @Query(ModelTask.fetchUnCompletedDownloadTask)
    private var uncompletedDownloadTasks: [ModelTask] = []
    
    @State private var draft = Message(role: .user)
    @State private var voiceState: VoiceState = .idle
    @State private var composerHeight: CGFloat = 0
    @State private var selectedCommand: ChatCommand = .compact
    @State private var projectEdition: Project?
    
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
            .sheet(item: $projectEdition) { project in
                ProjectEdition(project: project)
                    .presentationDetents([.medium, .large])
            }
            .onChange(of: localModelStore.models, initial: true) { _, availableModels in
                guard globalStore.selectedModel == nil else { return }
                globalStore.selectedModel = availableModels.first
            }
            .onChange(of: globalStore.selectedModel, initial: true) {
                refreshContextUsage()
            }
            .onChange(of: chat?.messages.count) {
                refreshContextUsage()
            }
            .onChange(of: chat?.summary) {
                refreshContextUsage()
            }
            .onChange(of: draft.content) {
                if draft.content == "/" {
                    selectedCommand = .compact
                }
            }
            .modifier(AudioLevelChangeModifier { transcript in
                _ = submitMessage(content: transcript, files: [])
            })
    }
}

private extension ChatView {
    
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
        if let chat = chat {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    globalStore.startNewChat()
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
    func ModelPickerButton() -> some View {
        Menu {
            ModelPicker()
        } label: {
            HStack(spacing: 4) {
                Text(globalStore.selectedModel?.displayName ?? String(localized: "Select Model"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 160)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
    }

    @ViewBuilder
    func ProjectPickerButton() -> some View {
        Menu {
            if !projects.isEmpty {
                if globalStore.newChatProject != nil {
                    Button {
                        globalStore.newChatProject = nil
                    } label: {
                        Text("No Project")
                    }

                    Divider()
                }

                ForEach(projects) { project in
                    Button {
                        globalStore.newChatProject = project
                    } label: {
                        Text(project.title)
                        if globalStore.newChatProject == project {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Divider()
            }

            Button {
                projectEdition = Project()
            } label: {
                Label("New Project", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
        } label: {
            Label(
                globalStore.newChatProject?.title ?? String(localized: "Choose Project"),
                systemImage: "folder")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
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
        if let chat = chat {
            ZStack(alignment: .bottom) {
                let messages = chat.sortedMessages
                let items = ConversationContentBuilder.items(from: messages)
                let lastItemID = items.last?.id
                ScrollViewReader { proxy in
                    ScrollView {
                        ConversationItemsView(items: items)
                            .environment(chatService)
                            .safeAreaPadding()
                            .background(SmallScrollerConfigurator())
                        
                        if !sttService.transcript.isEmpty {
                            Text(sttService.transcript)
                                .padding()
                                .animation(.easeInOut, value: sttService.transcript)
                        }
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
                ComposerView(showsProjectPicker: false)
                    .shadow(color: Color.primary.opacity(0.1), radius: 8, x: 0, y: -4)
                    .safeAreaPadding()
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { composerHeight in
                        self.composerHeight = composerHeight
                    }
            }
        } else {
            NewChatLandingView {
                ComposerView(showsProjectPicker: true)
            }
            .safeAreaPadding()
        }
    }

    @ViewBuilder
    func ComposerView(showsProjectPicker: Bool) -> some View {
        VStack(spacing: 8) {
            if let pendingDecision = chatService.decisionCoordinator.pendingDecision {
                DecisionRequestView(
                    pendingDecision: pendingDecision,
                    onConfirm: chatService.decisionCoordinator.submit)
                .id(pendingDecision.id)
            }

            if isCommandPalettePresented {
                ChatCommandPalette(
                    selectedCommand: selectedCommand,
                    isEnabled: isCommandEnabled,
                    onSelect: runCommand)
            }

            ChatInputView(
                userInput: draft,
                trailing: {
                    HStack {
                        if let contextUsage = chatService.contextUsage {
                            ContextWindowProgressView(usage: contextUsage)
                        }

                        ModelPickerButton()

                        if chatService.isCompacting {
                            ProgressView()
                                .controlSize(.small)
                        } else if isAgentExecuting {
                            if !draft.content.isEmpty && !isCommandPalettePresented {
                                SubmitMessageButton()
                            }
                            StopGeneratingMessageButton()
                        } else if draft.content.isEmpty {
                            voiceModeButton()
                        } else {
                            SubmitMessageButton()
                        }
                    }
                }
            )
            .onKeyPress(
                keys: [.upArrow, .downArrow, .return, .escape],
                phases: [.down, .repeat],
                action: handleCommandKeyPress)

            if showsProjectPicker {
                HStack {
                    ProjectPickerButton()
                    Spacer()
                }
                .padding(.horizontal)
            }
        }
    }
}

private struct NewChatLandingView<Composer: View>: View {

    @ViewBuilder let composer: Composer

    var body: some View {
        VStack(spacing: 24) {
            Text("How can I help you today?")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            composer
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SmallScrollerConfigurator: NSViewRepresentable {

    func makeNSView(context: Context) -> ConfiguratorView {
        ConfiguratorView()
    }

    func updateNSView(_ nsView: ConfiguratorView, context: Context) {
        nsView.configureScroller()
    }

    final class ConfiguratorView: NSView {

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureScroller()
        }

        func configureScroller() {
            enclosingScrollView?.verticalScroller?.controlSize = .small
        }
    }
}

private extension ChatView {

    var isAgentExecuting: Bool {
        guard let chat else { return false }
        return chat.isGenerating || chatService.isPreparingResponse
    }

    var isCommandPalettePresented: Bool {
        draft.content == "/"
    }

    func isCommandEnabled(_ command: ChatCommand) -> Bool {
        switch command {
        case .compact:
            return chat?.messages.isEmpty == false
                && globalStore.selectedModel != nil
                && !isAgentExecuting
                && !chatService.isCompacting
        }
    }

    func handleCommandKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        guard isCommandPalettePresented else { return .ignored }

        switch keyPress.key {
        case .upArrow:
            selectPreviousCommand()
        case .downArrow:
            selectNextCommand()
        case .return:
            runCommand(selectedCommand)
        case .escape:
            draft.content = ""
        default:
            return .ignored
        }
        return .handled
    }

    func selectPreviousCommand() {
        let commands = ChatCommand.allCases
        guard let index = commands.firstIndex(of: selectedCommand) else { return }
        selectedCommand = commands[(index - 1 + commands.count) % commands.count]
    }

    func selectNextCommand() {
        let commands = ChatCommand.allCases
        guard let index = commands.firstIndex(of: selectedCommand) else { return }
        selectedCommand = commands[(index + 1) % commands.count]
    }

    func runCommand(_ command: ChatCommand) {
        guard isCommandEnabled(command) else { return }
        draft.content = ""

        switch command {
        case .compact:
            guard let model = globalStore.selectedModel,
                  let chat else {
                return
            }
            Task {
                try await chatService.compactContext(model: model, chat: chat)
                refreshContextUsage()
            }
        }
    }
    
    func submitMessage(content: String, files: [URL]) -> Bool {
        guard let model = globalStore.selectedModel,
              !chatService.isCompacting else {
            return false
        }
        let activeChat: Chat
        if let chat = chat {
            activeChat = chat
        } else {
            activeChat = chatService.createChat(project: globalStore.newChatProject)
            globalStore.currentTab = .chat(activeChat)
            globalStore.newChatProject = nil
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

    func refreshContextUsage() {
        chatService.scheduleContextUsage(
            model: globalStore.selectedModel,
            chat: chat)
    }
    
    func scrollToBottom(_ proxy: ScrollViewProxy, lastID: ConversationContentItem.ID?) {
        guard let lastID else { return }
        withAnimation {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}

private enum ChatCommand: String, CaseIterable, Identifiable {
    case compact

    var id: Self { self }

    var title: String {
        "/\(rawValue)"
    }

    var description: LocalizedStringResource {
        switch self {
        case .compact:
            "Compress conversation history to free context space."
        }
    }
}

private struct ChatCommandPalette: View {

    let selectedCommand: ChatCommand
    let isEnabled: (ChatCommand) -> Bool
    let onSelect: (ChatCommand) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(ChatCommand.allCases) { command in
                Button {
                    onSelect(command)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(command.title)
                                .font(.body.monospaced())
                            Text(command.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        selectedCommand == command
                            ? Color.accentColor.opacity(0.14)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled(command))
            }
        }
        .padding(6)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator)
        }
    }
}

private struct ContextWindowProgressView: View {

    let usage: ContextWindowUsage

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 2)

            Circle()
                .trim(from: 0, to: usage.fraction)
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .help(helpText)
        .accessibilityLabel("Context window usage")
        .accessibilityValue(Text(accessibilityValue))
    }

    private var helpText: String {
        return String(localized: "\(usage.usedTokens.formatted()) of \(usage.totalTokens.formatted()) context tokens")
    }

    private var accessibilityValue: String {
        return usage.fraction.formatted(.percent.precision(.fractionLength(0)))
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
