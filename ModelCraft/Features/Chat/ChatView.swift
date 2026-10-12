//
//  ChatView.swift
//  ModelCraft
//
//  Created by Hongshen on 23/3/24.
//

import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers


struct ChatView: View {

    let chat: Chat?
    
    @Query(Project.fetch()) private var projects: [Project]
    
    @Query(ModelTask.fetchUnCompletedDownloadTask)
    private var uncompletedDownloadTasks: [ModelTask] = []
    
    @State private var draft = Message(role: .user)
    @State private var voiceState: VoiceState = .idle
    @State private var voiceTask: Task<Void, Never>?
    @State private var composerHeight: CGFloat = 0
    @State private var skillCommands: [ChatCommand] = []
    @State private var selectedCommand: ChatCommand = .compact
    @State private var composerSelectionLocation = 0
    @State private var slashCommandLocation: Int?
    @State private var projectEdition: Project?
    
    enum VoiceState {
        case idle
        case loading
        case listening
        case responding
    }

    /// The voice mode phase shown in the composer, or `nil` outside voice mode.
    var voicePhase: VoicePhase? {
        switch voiceState {
        case .idle: nil
        case .loading: .loading
        case .listening: sttService.isHearingSpeech ? .hearing : .waiting
        case .responding: ttsService.isPlaying ? .speaking : .thinking
        }
    }
    
    @Environment(GlobalStore.self) private var globalStore
    @Environment(LocalModelStore.self) private var localModelStore
    @Environment(STTService.self) private var sttService
    @Environment(TTSService.self) private var ttsService
    
    @State private var chatService = ChatService()
    private static let minWidth: CGFloat = 270
    
    var body: some View {
        MainView()
            .frame(minWidth: ChatView.minWidth, minHeight: 250)
            .toolbar(content: ToolbarItems)
            .environment(\.openURL, OpenURLAction(handler: openURL))
            .sheet(item: $projectEdition) { project in
                ProjectEdition(project: project)
                    .presentationDetents([.medium, .large])
            }
            .onChange(of: localModelStore.models, initial: true) { _, availableModels in
                guard globalStore.selectedModel == nil else { return }
                globalStore.selectedModel = availableModels.first
            }
            .onChange(of: slashCommandLocation) {
                if slashCommandLocation != nil {
                    reloadCommands()
                }
            }
            .onChange(of: chat?.id) {
                globalStore.isFileInspectorPresented = false
                globalStore.previewURL = nil
            }
            .onChange(of: chat?.sortedMessages.last?.content) {
                guard voiceState == .responding,
                      let message = chat?.sortedMessages.last,
                      message.role == .assistant else { return }
                ttsService.feed(message.content, messageID: message.id)
            }
            .onDisappear(perform: stopVoiceMode)
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
        Button(action: startVoiceMode) {
            Image(systemName: "waveform")
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .disabled(globalStore.selectedModel == nil)
        .help("Voice Mode")
        .accessibilityLabel("Start Voice Mode")
    }

    /// The level bars, mute, and end controls that replace the send button in voice mode.
    @ViewBuilder
    func VoiceControls(phase: VoicePhase) -> some View {
        @Bindable var sttService = self.sttService
        HStack {
            VoiceLevelView(phase: phase, level: sttService.level)
                .padding(.horizontal, 4)

            Toggle(isOn: $sttService.isMuted) {
                Image(systemName: sttService.isMuted ? "mic.slash.fill" : "mic.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .toggleStyle(.button)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .disabled(phase == .loading)
            .help(sttService.isMuted ? "Unmute Microphone" : "Mute Microphone")
            .accessibilityLabel(sttService.isMuted ? "Unmute Microphone" : "Mute Microphone")

            Button(action: stopVoiceMode) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
            .help("End Voice Mode")
            .accessibilityLabel("End Voice Mode")
        }
    }
    
    
    @ViewBuilder
    func StopGeneratingMessageButton() -> some View {
        Button {
            Task {
                if let chat {
                    await chatService.stopGenerating(chat: chat)
                }
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
        let pendingInteraction = chatService.interactionCoordinator.pendingInteraction
        VStack(spacing: 8) {
            if isCommandPalettePresented {
                ChatCommandPalette(
                    skillCommands: skillCommands,
                    selectedCommand: selectedCommand,
                    isEnabled: isCommandEnabled,
                    onSelect: runCommand)
            }

            // A pending request covers the input. The ZStack is as large as its larger
            // child, so the request is as wide as the input, at least as tall, and taller
            // when its content needs it.
            ZStack(alignment: .top) {
                ChatInputView(
                    userInput: draft,
                    skillNames: skillCommands.compactMap(\.skillName),
                    placeholder: voicePhase == nil ? "Type Anything" : "Add text or files to what you say next",
                    selectionLocation: $composerSelectionLocation,
                    slashCommandLocation: $slashCommandLocation,
                    onCommand: handleComposerCommand,
                    header: {
                        // The utterance being recorded, shown until it is sent.
                        if voicePhase != nil, !sttService.transcript.isEmpty {
                            Text(verbatim: sttService.transcript)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    },
                    trailing: {
                        HStack {
                            if let chat, let contextWindow = globalStore.selectedModel?.contextWindow, contextWindow > 0 {
                                ContextWindowUsageView(tokenCount: chat.tokenCount, contextWindow: contextWindow)
                            }

                            ModelPickerButton()

                            if chatService.isCompacting {
                                ProgressView()
                                    .controlSize(.small)
                            } else if let voicePhase {
                                VoiceControls(phase: voicePhase)
                            } else if !draft.content.isEmpty {
                                SubmitMessageButton()
                            } else if chat?.isGenerating == true {
                                StopGeneratingMessageButton()
                            } else {
                                voiceModeButton()
                            }
                        }
                    }
                )
                .onKeyPress(
                    keys: [.upArrow, .downArrow, .return, .escape],
                    phases: [.down, .repeat],
                    action: handleCommandKeyPress)
                .opacity(pendingInteraction == nil ? 1 : 0)
                .disabled(pendingInteraction != nil)
                .accessibilityHidden(pendingInteraction != nil)

                if let pendingInteraction {
                    UserInteractionRequestView(
                        pendingInteraction: pendingInteraction,
                        onSubmitUserInput: chatService.interactionCoordinator.submitUserInput,
                        onResolveApproval: chatService.interactionCoordinator.resolveApproval)
                    .id(pendingInteraction.id)
                }
            }
            .background {
                if pendingInteraction != nil {
                    RoundedRectangle().fill(.background)
                }
            }

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
        return chat.isGenerating
    }

    var isCommandPalettePresented: Bool {
        slashCommandLocation != nil
    }

    var commands: [ChatCommand] {
        [.compact] + skillCommands
    }

    func isCommandEnabled(_ command: ChatCommand) -> Bool {
        switch command {
        case .compact:
            return chat?.messages.isEmpty == false
                && globalStore.selectedModel != nil
                && chat?.isGenerating != true
                && !chatService.isCompacting
        case .skill:
            return true
        }
    }

    func reloadCommands() {
        SkillManager.shared.loadSkills()
        skillCommands = SkillManager.shared.skills.values
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { .skill(name: $0.name, description: $0.description) }
        selectedCommand = .compact
    }

    func handleCommandKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        let command: ChatComposerCommand
        switch keyPress.key {
        case .upArrow:
            command = .previous
        case .downArrow:
            command = .next
        case .return:
            command = .select
        case .escape:
            command = .dismiss
        default:
            return .ignored
        }
        return handleComposerCommand(command) ? .handled : .ignored
    }

    func handleComposerCommand(_ command: ChatComposerCommand) -> Bool {
        guard isCommandPalettePresented else { return false }
        switch command {
        case .previous:
            selectPreviousCommand()
        case .next:
            selectNextCommand()
        case .select:
            runCommand(selectedCommand)
        case .dismiss:
            replaceCommandSlash(with: "")
        }
        return true
    }

    func selectPreviousCommand() {
        guard let index = commands.firstIndex(of: selectedCommand) else { return }
        selectedCommand = commands[(index - 1 + commands.count) % commands.count]
    }

    func selectNextCommand() {
        guard let index = commands.firstIndex(of: selectedCommand) else { return }
        selectedCommand = commands[(index + 1) % commands.count]
    }

    func runCommand(_ command: ChatCommand) {
        guard isCommandEnabled(command) else { return }

        switch command {
        case .compact:
            replaceCommandSlash(with: "")
            guard let model = globalStore.selectedModel,
                  let chat else {
                return
            }
            Task {
                try await chatService.compactContext(model: model, chat: chat)
            }
        case .skill(let name, _):
            replaceCommandSlash(with: "/\(name) ")
        }
    }

    func replaceCommandSlash(with replacement: String) {
        guard let slashCommandLocation else { return }
        let content = draft.content as NSString
        guard slashCommandLocation < content.length else { return }
        draft.content = content.replacingCharacters(
            in: NSRange(location: slashCommandLocation, length: 1),
            with: replacement)
        composerSelectionLocation = slashCommandLocation + (replacement as NSString).length
        self.slashCommandLocation = nil
    }
    
    func submitMessage(content: String, files: [URL]) -> Bool {
        guard let model = globalStore.selectedModel,
              !chatService.isCompacting else {
            return false
        }
        let activeChat = openChat()
        let message = Message(
            role: .user,
            chat: activeChat,
            content: content,
            files: files)
        Task {
            try await chatService.sendMessage(
                model: model,
                chat: activeChat,
                message: message
            )
        }
        return true
    }

    /// The open chat, or a new chat that becomes the open one.
    func openChat() -> Chat {
        if let chat {
            return chat
        }
        let newChat = chatService.createChat(project: globalStore.newChatProject)
        globalStore.currentTab = .chat(newChat)
        globalStore.newChatProject = nil
        return newChat
    }

    func submitDraft() {
        if !submitMessage(content: draft.content, files: draft.files) {
            return
        }
        clearDraft()
    }

    /// Runs the voice conversation: listen to one utterance, send it, and speak the response
    /// while already listening for the next one. Talking over a response interrupts it.
    func startVoiceMode() {
        voiceState = .loading
        voiceTask = Task {
            await sttService.loadModel()
            await ttsService.loadModel()
            guard !Task.isCancelled else { return }
            // This view value keeps the `chat` it had when voice mode started, so the chat
            // created by the first turn is remembered here.
            var voiceChat = chat
            voiceState = .listening
            var utterance = await sttService.listen()
            while !Task.isCancelled,
                  let text = utterance,
                  let model = globalStore.selectedModel,
                  !chatService.isCompacting {
                if text.isEmpty {
                    utterance = await sttService.listen()
                    continue
                }
                let chat = voiceChat ?? openChat()
                voiceChat = chat

                voiceState = .responding
                ttsService.begin()
                async let nextUtterance = sttService.listen {
                    interruptVoiceResponse(in: chat)
                }
                // Text and files added to the composer go with the utterance.
                let note = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = Message(
                    role: .user,
                    chat: chat,
                    content: note.isEmpty ? text : "\(note)\n\n\(text)",
                    files: draft.files)
                clearDraft()
                try? await chatService.sendMessage(model: model, chat: chat, message: message)
                // Speak the text that arrived after the last streamed change.
                for reply in chat.sortedMessages.drop(while: { $0 != message }) where reply.role == .assistant {
                    ttsService.feed(reply.content, messageID: reply.id, isComplete: true)
                }
                await ttsService.finish()
                guard !Task.isCancelled else { return }

                voiceState = .listening
                utterance = await nextUtterance
            }
            // Ended without `stopVoiceMode()`, for example because recording failed.
            if !Task.isCancelled {
                stopVoiceMode()
            }
        }
    }

    /// Stops speaking and generating as soon as the user starts talking over a response,
    /// including while the model is still compacting, prefilling, or thinking.
    func interruptVoiceResponse(in chat: Chat) {
        guard voiceState == .responding else { return }
        voiceState = .listening
        ttsService.stop()
        Task { await chatService.stopGenerating(chat: chat) }
    }

    /// Cancelling the voice task also ends any `listen()` in progress.
    func stopVoiceMode() {
        guard voiceState != .idle else { return }
        voiceTask?.cancel()
        voiceTask = nil
        ttsService.stop()
        if voiceState == .responding, let chat {
            Task { await chatService.stopGenerating(chat: chat) }
        }
        sttService.isMuted = false
        voiceState = .idle
    }
    
    func clearDraft() {
        draft.content = ""
        draft.files = []
        composerSelectionLocation = 0
        slashCommandLocation = nil
    }

    func openURL(_ url: URL) -> OpenURLAction.Result {
        let path: String
        if let requestedPath = FilePreviewLink.path(from: url) {
            path = requestedPath
        } else if url.isFileURL {
            path = url.path
        } else if url.scheme == nil {
            path = url.relativePath
        } else {
            return .systemAction
        }

        guard let url = resolvedPreviewURL(for: path) else {
            return .discarded
        }

        globalStore.previewURL = url
        globalStore.isFileInspectorPresented = true
        return .handled
    }

    func resolvedPreviewURL(for path: String) -> URL? {
        let baseURL = chat?.project?.workingDirectory ?? .documentsDirectory
        let url = URL(
            fileURLWithPath: (path as NSString).expandingTildeInPath,
            relativeTo: baseURL
        )
        .standardizedFileURL
        .resolvingSymlinksInPath()

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }

        guard let project = chat?.project else {
            return url
        }

        let roots = [project.workingDirectory].compactMap { $0 } + project.resources
        guard roots.contains(where: { contains(url, root: $0) }) else {
            return nil
        }
        return url
    }

    func contains(_ candidate: URL, root: URL) -> Bool {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        if candidate == root {
            return true
        }

        let values = try? root.resourceValues(forKeys: [.isDirectoryKey])
        return values?.isDirectory == true
            && candidate.pathComponents.starts(with: root.pathComponents)
    }
    
    func scrollToBottom(_ proxy: ScrollViewProxy, lastID: ConversationContentItem.ID?) {
        guard let lastID else { return }
        withAnimation {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}

private enum ChatCommand: Identifiable, Equatable {
    case compact
    case skill(name: String, description: String)

    var id: String {
        switch self {
        case .compact:
            "command:compact"
        case .skill(let name, _):
            "skill:\(name)"
        }
    }

    var title: String {
        switch self {
        case .compact:
            "/compact"
        case .skill(let name, _):
            "/\(name)"
        }
    }

    var icon: String {
        switch self {
        case .compact:
            "arrow.down.right.and.arrow.up.left"
        case .skill:
            "cube"
        }
    }

    var skillName: String? {
        switch self {
        case .compact:
            nil
        case .skill(let name, _):
            name
        }
    }
}

private struct ChatCommandPalette: View {

    let skillCommands: [ChatCommand]
    let selectedCommand: ChatCommand
    let isEnabled: (ChatCommand) -> Bool
    let onSelect: (ChatCommand) -> Void

    var body: some View {
        ViewThatFits(in: .vertical) {
            ChatCommandPaletteContent(
                skillCommands: skillCommands,
                selectedCommand: selectedCommand,
                isEnabled: isEnabled,
                onSelect: onSelect)

            ScrollViewReader { proxy in
                ScrollView {
                    ChatCommandPaletteContent(
                        skillCommands: skillCommands,
                        selectedCommand: selectedCommand,
                        isEnabled: isEnabled,
                        onSelect: onSelect)
                }
                .onChange(of: selectedCommand) {
                    proxy.scrollTo(selectedCommand.id, anchor: .center)
                }
            }
        }
        .frame(maxHeight: 320)
        .padding(6)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator)
        }
    }
}

private struct ChatCommandPaletteContent: View {

    let skillCommands: [ChatCommand]
    let selectedCommand: ChatCommand
    let isEnabled: (ChatCommand) -> Bool
    let onSelect: (ChatCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChatCommandSection(
                commands: [.compact],
                selectedCommand: selectedCommand,
                isEnabled: isEnabled,
                onSelect: onSelect)

            if !skillCommands.isEmpty {
                Text("Skills")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)

                ChatCommandSection(
                    commands: skillCommands,
                    selectedCommand: selectedCommand,
                    isEnabled: isEnabled,
                    onSelect: onSelect)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ChatCommandSection: View {

    let commands: [ChatCommand]
    let selectedCommand: ChatCommand
    let isEnabled: (ChatCommand) -> Bool
    let onSelect: (ChatCommand) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(commands) { command in
                Button {
                    onSelect(command)
                } label: {
                    ChatCommandRow(
                        command: command,
                        isSelected: selectedCommand == command)
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled(command))
                .id(command.id)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ChatCommandRow: View {

    let command: ChatCommand
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: command.icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)

            Text(command.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            switch command {
            case .compact:
                Text(
                    "Compress conversation history to free context space.",
                    comment: "Description of the slash command that manually compacts chat context.")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            case .skill(_, let description):
                Text(description)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct UserInteractionRequestView: View {

    let pendingInteraction: UserInteractionCoordinator.PendingInteraction
    let onSubmitUserInput: ([UserInputAnswer]) -> Void
    let onResolveApproval: (ToolApprovalDecision) -> Void

    var body: some View {
        VStack {
            switch pendingInteraction {
            case .userInput(let pendingUserInput):
                UserInputRequestView(
                    pendingUserInput: pendingUserInput,
                    onConfirm: onSubmitUserInput)
                    // A new request starts on its first page with empty answers.
                    .id(pendingUserInput.id)
            case .approval(let pendingApproval):
                ToolApprovalRequestView(
                    request: pendingApproval.request,
                    onResolve: onResolveApproval)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UserInputRequestView: View {

    let pendingUserInput: UserInteractionCoordinator.PendingUserInput
    let onConfirm: ([UserInputAnswer]) -> Void

    @State private var form = UserInputFormModel()
    @State private var fileImporterPresented = false
    @State private var importingFieldID: String?
    @State private var fileImportError: String?

    /// The position of the question on screen.
    @State private var page = 0

    private var fields: [UserInputField] {
        pendingUserInput.request.fields
    }

    var body: some View {
        let field = fields[page]
        let isLastPage = page == fields.count - 1
        VStack(alignment: .leading, spacing: 12) {
            if fields.count > 1 {
                Text(verbatim: "\(page + 1) / \(fields.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            UserInputFieldView(
                field: field,
                form: form,
                onChooseFiles: presentFileImporter)
                .id(field.id)

            if let fileImportError {
                Text(fileImportError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                if page > 0 {
                    Button("Back") {
                        page -= 1
                    }
                }
                Spacer()
                Button("Skip") {
                    form.clear(field.id)
                    goForward()
                }
                Button(isLastPage ? LocalizedStringKey("Confirm") : LocalizedStringKey("Next")) {
                    goForward()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!form.hasAnswer(for: field))
            }
        }
        .padding()
        .fileImporter(
            isPresented: $fileImporterPresented,
            allowedContentTypes: importerContentTypes,
            allowsMultipleSelection: importerAllowsMultipleSelection
        ) { result in
            guard let importingFieldID else { return }
            switch result {
            case .success(let urls):
                form.setFiles(urls, for: importingFieldID)
                fileImportError = nil
            case .failure(let error):
                fileImportError = error.localizedDescription
            }
            self.importingFieldID = nil
        }
    }

    /// Shows the next question, or sends every answer after the last one.
    /// A skipped question is sent with no values.
    private func goForward() {
        if page < fields.count - 1 {
            page += 1
        } else {
            onConfirm(form.answers(for: fields))
        }
    }

    private var importingField: UserInputField? {
        fields.first { $0.id == importingFieldID }
    }

    private var importerContentTypes: [UTType] {
        importingField?.type == .directory ? [.folder] : [.item]
    }

    private var importerAllowsMultipleSelection: Bool {
        importingField?.allowsMultipleSelection == true
    }

    private func presentFileImporter(_ field: UserInputField) {
        importingFieldID = field.id
        fileImporterPresented = true
    }
}

private struct UserInputFieldView: View {

    let field: UserInputField
    let form: UserInputFormModel
    let onChooseFiles: (UserInputField) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(field.label)
                    .font(.headline)
                if let description = field.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            switch field.type {
            case .singleChoice, .multipleChoice:
                UserInputChoiceFieldView(field: field, form: form)
            case .text:
                UserInputTextFieldView(field: field, form: form, isMultiline: false)
            case .multilineText:
                UserInputTextFieldView(field: field, form: form, isMultiline: true)
            case .file, .directory:
                UserInputFileFieldView(
                    field: field,
                    selectedURLs: form.files(for: field.id),
                    onChoose: { onChooseFiles(field) })
            }
        }
    }
}

private struct UserInputChoiceFieldView: View {

    let field: UserInputField
    let form: UserInputFormModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(field.options ?? []) { option in
                Button {
                    form.select(option.id, in: field)
                } label: {
                    UserInputOptionLabel(
                        option: option,
                        selectionType: field.type,
                        isSelected: form.isSelected(option.id, in: field.id),
                        isRecommended: field.recommendedOptionID == option.id)
                }
                .buttonStyle(.plain)
            }

            if field.allowsCustomAnswer == true {
                Button {
                    form.selectCustomAnswer(in: field.id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: form.isCustom(field.id) ? "largecircle.fill.circle" : "circle")
                        Text("Custom")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if form.isCustom(field.id) {
                    UserInputTextFieldView(field: field, form: form, isMultiline: false)
                }
            }
        }
    }
}

private struct UserInputTextFieldView: View {

    let field: UserInputField
    let form: UserInputFormModel
    let isMultiline: Bool

    var body: some View {
        @Bindable var form = form
        TextField(
            field.placeholder ?? String(localized: "Enter your answer"),
            text: $form[textFor: field.id],
            axis: .vertical)
        .lineLimit(isMultiline ? 3...8 : 1...1)
        .textFieldStyle(.roundedBorder)
    }
}

private struct UserInputFileFieldView: View {

    let field: UserInputField
    let selectedURLs: [URL]
    let onChoose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(selectedURLs, id: \.self) { url in
                Label(url.lastPathComponent, systemImage: field.type == .directory ? "folder" : "doc")
                    .font(.caption)
            }

            Button(action: onChoose) {
                Text(pickerTitle)
            }
        }
    }

    private var pickerTitle: LocalizedStringResource {
        switch (field.type, field.allowsMultipleSelection == true) {
        case (.directory, true): "Choose Folders"
        case (.directory, false): "Choose Folder"
        case (.file, true): "Choose Files"
        default: "Choose File"
        }
    }
}

private struct UserInputOptionLabel: View {

    let option: UserInputOption
    let selectionType: UserInputFieldType
    let isSelected: Bool
    let isRecommended: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: selectionImageName)
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

    private var selectionImageName: String {
        switch selectionType {
        case .multipleChoice:
            isSelected ? "checkmark.square.fill" : "square"
        default:
            isSelected ? "largecircle.fill.circle" : "circle"
        }
    }
}

private struct ToolApprovalRequestView: View {

    let request: ToolApprovalRequest
    let onResolve: (ToolApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allow this action?")
                .font(.headline)

            Text(request.title)
            if let detail = request.detail, !detail.isEmpty {
                if request.allowsAlways {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    // An AppleScript: show the whole script so the user knows what runs.
                    let script = Text(verbatim: detail)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    ViewThatFits(in: .vertical) {
                        script
                        ScrollView {
                            script
                        }
                    }
                    .frame(maxHeight: 240)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                    if detail.localizedCaseInsensitiveContains("do shell script") {
                        Label(
                            "This script can run shell commands with ModelCraft's permissions.",
                            systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Deny") {
                    onResolve(.deny)
                }
                Button("Allow Once") {
                    onResolve(.allowOnce)
                }
                .buttonStyle(.borderedProminent)
                if request.allowsAlways {
                    Button("Always Allow") {
                        onResolve(.alwaysAllow)
                    }
                }
            }
        }
        .padding()
    }
}

@MainActor
@Observable
private final class UserInputFormModel {

    private var selectedOptionIDs: [String: Set<String>] = [:]
    private var customFieldIDs: Set<String> = []
    private var textAnswers: [String: String] = [:]
    private var selectedFiles: [String: [URL]] = [:]

    subscript(textFor fieldID: String) -> String {
        get { textAnswers[fieldID] ?? "" }
        set { textAnswers[fieldID] = newValue }
    }

    func select(_ optionID: String, in field: UserInputField) {
        customFieldIDs.remove(field.id)
        if field.type == .multipleChoice {
            var selections = selectedOptionIDs[field.id] ?? []
            if selections.contains(optionID) {
                selections.remove(optionID)
            } else {
                selections.insert(optionID)
            }
            selectedOptionIDs[field.id] = selections
        } else {
            selectedOptionIDs[field.id] = [optionID]
        }
    }

    func selectCustomAnswer(in fieldID: String) {
        customFieldIDs.insert(fieldID)
        selectedOptionIDs[fieldID] = []
    }

    func isSelected(_ optionID: String, in fieldID: String) -> Bool {
        !customFieldIDs.contains(fieldID)
            && selectedOptionIDs[fieldID]?.contains(optionID) == true
    }

    func isCustom(_ fieldID: String) -> Bool {
        customFieldIDs.contains(fieldID)
    }

    func setFiles(_ urls: [URL], for fieldID: String) {
        selectedFiles[fieldID] = urls
    }

    func files(for fieldID: String) -> [URL] {
        selectedFiles[fieldID] ?? []
    }

    func hasAnswer(for field: UserInputField) -> Bool {
        !values(for: field).isEmpty
    }

    /// Removes the answer of a skipped question.
    func clear(_ fieldID: String) {
        selectedOptionIDs[fieldID] = nil
        customFieldIDs.remove(fieldID)
        textAnswers[fieldID] = nil
        selectedFiles[fieldID] = nil
    }

    func answers(for fields: [UserInputField]) -> [UserInputAnswer] {
        fields.map { field in
            UserInputAnswer(fieldID: field.id, values: values(for: field))
        }
    }

    private func values(for field: UserInputField) -> [String] {
        switch field.type {
        case .singleChoice, .multipleChoice:
            if customFieldIDs.contains(field.id) {
                return trimmedText(for: field.id).map { [$0] } ?? []
            }
            let selections = selectedOptionIDs[field.id] ?? []
            return (field.options ?? []).compactMap { option in
                selections.contains(option.id) ? option.id : nil
            }
        case .text, .multilineText:
            return trimmedText(for: field.id).map { [$0] } ?? []
        case .file, .directory:
            return (selectedFiles[field.id] ?? []).map(\.path)
        }
    }

    private func trimmedText(for fieldID: String) -> String? {
        let value = (textAnswers[fieldID] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
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

#Preview(traits: .preview) {
    ChatView(chat: .preview)
        .frame(width: 760, height: 900)
}

// MARK: - Voice mode

/// What voice mode is doing, as shown in the composer.
enum VoicePhase {
    case loading
    /// Listening and waiting for the user to start speaking.
    case waiting
    /// Recording an utterance.
    case hearing
    /// A response is being generated and nothing is spoken yet.
    case thinking
    case speaking
}

/// Bars that follow the microphone while listening, move with the voice while speaking,
/// and pulse while thinking.
struct VoiceLevelView: View {

    let phase: VoicePhase
    let level: Float

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barCount = 5
    /// Middle bars react more than the outer ones.
    private static let barWeights: [Double] = [0.5, 0.8, 1, 0.8, 0.5]
    private static let minHeight: Double = 4
    private static let maxHeight: Double = 20

    var body: some View {
        if phase == .loading {
            ProgressView()
                .controlSize(.small)
        } else {
            TimelineView(.animation(paused: reduceMotion)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 3) {
                    ForEach(0..<Self.barCount, id: \.self) { index in
                        Capsule()
                            .fill(.tint)
                            .frame(width: 3, height: height(of: index, at: time))
                            .opacity(opacity(of: index, at: time))
                    }
                }
                .frame(height: Self.maxHeight)
            }
            .animation(.easeOut(duration: 0.1), value: level)
            .accessibilityHidden(true)
        }
    }

    private func height(of index: Int, at time: TimeInterval) -> Double {
        let weight = Self.barWeights[index]
        let phaseOffset = Double(index) * 1.3
        let amplitude: Double
        switch phase {
        case .loading, .thinking:
            amplitude = 0
        case .waiting, .hearing:
            // A slight idle motion keeps the bars alive while the room is quiet.
            amplitude = max(Double(level), 0.08 + 0.05 * sin(time * 2 + phaseOffset)) * weight
        case .speaking:
            amplitude = (0.5 + 0.5 * sin(time * 7 + phaseOffset)) * (0.6 + 0.4 * sin(time * 2.3 + phaseOffset)) * weight
        }
        return Self.minHeight + (Self.maxHeight - Self.minHeight) * min(amplitude, 1)
    }

    private func opacity(of index: Int, at time: TimeInterval) -> Double {
        guard phase == .thinking else { return 1 }
        return 0.3 + 0.7 * max(0, sin(time * 4 - Double(index) * 0.6))
    }
}
