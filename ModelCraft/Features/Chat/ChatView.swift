//
//  ChatView.swift
//  ModelCraft
//
//  Created by Hongshen on 23/3/24.
//

import SwiftUI
import KeyboardShortcuts
import SwiftData
import AppKit
import UniformTypeIdentifiers


struct ChatView: View {

    let chat: Chat?
    
    @Query(Project.fetch()) private var projects: [Project]
    
    @Query(ModelTask.fetchUnCompletedDownloadTask)
    private var uncompletedDownloadTasks: [ModelTask] = []
    
    @State private var draft = Message(role: .user)
    @State private var isRewinding = false
    @State private var voiceInputTask: Task<Void, Never>?
    @State private var voiceInputError: String?
    @State private var skillCommands: [ChatCommand] = []
    @State private var selectedCommand: ChatCommand = .compact
    @State private var composerSelectionLocation = 0
    @State private var slashCommandLocation: Int?
    @State private var projectEdition: Project?
    @State private var requestError: String?
    @State private var inspectorTab = ChatInspectorTab.tasks
    @State private var isDropTargeted = false
    @AppStorage(UserDefaults.toolPermissionMode)
    private var toolPermissionMode = UserDefaultSettings.toolPermissionMode
    @Environment(\.controlActiveState) private var controlActiveState

    @Environment(GlobalStore.self) private var globalStore
    @Environment(LocalModelStore.self) private var localModelStore
    @Environment(STTService.self) private var sttService
    
    @State private var chatService = ChatService()
    private static let minWidth: CGFloat = 270
    
    var body: some View {
        @Bindable var bindableStore = globalStore
        MainView()
            .frame(minWidth: ChatView.minWidth, minHeight: 250)
            .dropDestination(for: URL.self) { urls, _ in
                draft.addFiles(urls)
                return true
            } isTargeted: {
                isDropTargeted = $0
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle()
                        .strokeBorder(.tint, lineWidth: 2)
                        .background(.tint.opacity(0.08), in: RoundedRectangle())
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .toolbar(content: ToolbarItems)
            .inspector(isPresented: $bindableStore.isInspectorPresented) {
                VStack(spacing: 0) {
                    ChatInspectorHeader(tab: $inspectorTab, isPresented: $bindableStore.isInspectorPresented)
                    Divider()
                    ZStack {
                        TaskInspectorView(
                            chat: chat,
                            project: chat == nil ? globalStore.newChatProject : chat?.project)
                            .opacity(inspectorTab == .tasks ? 1 : 0)
                            .allowsHitTesting(inspectorTab == .tasks)
                            .accessibilityHidden(inspectorTab != .tasks)
                        FileInspectorView(url: globalStore.previewURL)
                            .opacity(inspectorTab == .files ? 1 : 0)
                            .allowsHitTesting(inspectorTab == .files)
                            .accessibilityHidden(inspectorTab != .files)
                    }
                }
                .inspectorColumnWidth(min: 300, ideal: 400, max: 700)
            }
            .environment(\.openURL, OpenURLAction(handler: openURL))
            .sheet(item: $projectEdition) { project in
                ProjectEdition(project: project)
                    .presentationDetents([.medium, .large])
            }
            .alert("Request Failed", isPresented: Binding(
                get: { requestError != nil },
                set: { if !$0 { requestError = nil } }
            )) {
                Button("OK") { requestError = nil }
            } message: {
                Text(requestError ?? "")
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
                cancelVoiceInput()
                globalStore.previewURL = nil
                inspectorTab = .tasks
            }
            .onChange(of: globalStore.newChatFiles, initial: true) {
                // Read from the store, not the new value, so with several windows only
                // the first takes the files.
                let files = globalStore.newChatFiles
                guard !files.isEmpty else { return }
                globalStore.newChatFiles = []
                draft.addFiles(files)
            }
            .onChange(of: globalStore.newChatPrompt, initial: true) {
                guard let prompt = globalStore.newChatPrompt else { return }
                globalStore.newChatPrompt = nil
                if !submitMessage(content: prompt.content, files: prompt.files) {
                    // No model to send with yet; keep the request in the composer.
                    draft.content = prompt.content
                    draft.files.append(contentsOf: prompt.files)
                }
            }
            .alert("Voice Input Failed", isPresented: Binding(
                get: { voiceInputError != nil },
                set: { if !$0 { voiceInputError = nil } }
            )) {
                Button("OK") { voiceInputError = nil }
            } message: {
                Text(voiceInputError ?? "")
            }
            .onChange(of: chatService.interactionCoordinator.pendingInteraction?.id) {
                if chatService.interactionCoordinator.pendingInteraction != nil {
                    cancelVoiceInput()
                }
            }
            .task(id: controlActiveState == .key) {
                guard controlActiveState == .key else { return }
                for await _ in KeyboardShortcuts.events(.keyDown, for: .voiceInput) {
                    guard !Task.isCancelled, controlActiveState == .key else { return }
                    toggleVoiceInput()
                }
            }
            .onDisappear(perform: cancelVoiceInput)
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
        ToolbarItemGroup(placement: .primaryAction) {
            if chat != nil {
                Button {
                    globalStore.startNewChat()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
            Button("Inspector", systemImage: "sidebar.right") {
                globalStore.isInspectorPresented.toggle()
            }
            .labelStyle(.iconOnly)
            .help("Inspector")
        }
    }

    @ViewBuilder
    func PermissionModePickerButton() -> some View {
        Menu {
            Picker("Permission Mode", selection: $toolPermissionMode) {
                ForEach(ToolPermissionMode.allCases) { mode in
                    Label {
                        Text(mode.title)
                    } icon: {
                        Image(systemName: mode.systemImage)
                    }
                    .tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: toolPermissionMode.systemImage)
                    .accessibilityHidden(true)
                Text(toolPermissionMode.title)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose which actions run without asking")
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
    func VoiceInputButton() -> some View {
        Button(action: startVoiceInput) {
            Image(systemName: "mic")
                .font(.title3)
                .frame(width: 36, height: 36)
                .background(.quaternary, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(sttService.state != .idle)
        .help("Voice Input")
        .accessibilityLabel("Start Voice Input")
    }

    @ViewBuilder
    func VoiceInputContent() -> some View {
        HStack(spacing: 8) {
            Button(action: cancelVoiceInput) {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Cancel Voice Input")

            VoiceLevelView(sttService: sttService)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    func FinishVoiceInputButton() -> some View {
        Button(action: sttService.stop) {
            Image(systemName: "pause.fill")
                .font(.title3)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .frame(width: 36, height: 36)
        .disabled(sttService.state != .recording)
        .accessibilityLabel("Stop Recording and Transcribe")
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
                .font(.title3)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .frame(width: 36, height: 36)
        .accessibilityLabel("Stop Generating")
    }
    
    @ViewBuilder
    func SubmitMessageButton() -> some View {
        let disabled = globalStore.selectedModel == nil || (draft.content.isEmpty && draft.files.isEmpty) || isRewinding
        Button(action: submitDraft) {
            Image(systemName: "arrow.up")
                .font(.title3)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .frame(width: 36, height: 36)
        .disabled(disabled)
        .accessibilityLabel("Send Message")
    }
    
    @ViewBuilder
    func MainView() -> some View {
        if let chat = chat {
            VStack(spacing: 0) {
                let messages = chat.conversation
                let items = ConversationContentBuilder.items(from: messages)
                let lastItemID = items.last?.id
                let bottomTransitionHeight: CGFloat = 32
                ScrollViewReader { proxy in
                    ScrollView {
                        ConversationItemsView(items: items, onRewind: rewindMessage)
                            .disabled(isRewinding)
                            .environment(chatService)
                            .safeAreaPadding()
                            .background(SmallScrollerConfigurator())
                    }
                    .contentMargins(.leading, Layout.padding, for: .scrollContent)
                    .contentMargins(.bottom, bottomTransitionHeight, for: .scrollContent)
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
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .frame(height: bottomTransitionHeight)
                        .mask {
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: bottomTransitionHeight)
                    }
                }
                .clipped()
                ComposerView(showsProjectPicker: false)
                    .shadow(color: Color.primary.opacity(0.1), radius: 8, x: 0, y: -4)
                    .safeAreaPadding()
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
                    placeholder: "Type Anything",
                    selectionLocation: $composerSelectionLocation,
                    slashCommandLocation: $slashCommandLocation,
                    onCommand: handleEditorCommand,
                    isVoiceInputActive: voiceInputTask != nil,
                    voiceContent: { VoiceInputContent() },
                    trailing: {
                        if voiceInputTask != nil {
                            FinishVoiceInputButton()
                        } else if chatService.isCompacting {
                            ProgressView()
                                .controlSize(.small)
                        } else if draft.content.isEmpty, draft.files.isEmpty {
                            if chat?.isGenerating == true {
                                StopGeneratingMessageButton()
                            } else {
                                VoiceInputButton()
                            }
                        } else {
                            SubmitMessageButton()
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
                    RoundedRectangle().fill(.surface)
                }
            }

            HStack(spacing: 12) {
                PermissionModePickerButton()
                ModelPickerButton()
                if showsProjectPicker {
                    ProjectPickerButton()
                }
                Spacer(minLength: 0)
                if let chat, let model = globalStore.selectedModel, model.contextWindow > 0 {
                    ContextWindowUsageView(chat: chat, model: model)
                }
            }
            .disabled(voiceInputTask != nil || pendingInteraction != nil)
            .padding(.horizontal, 12)
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
        voiceInputTask == nil && slashCommandLocation != nil
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

    /// Return in the text editor runs the selected palette command, or else sends the draft.
    func handleEditorCommand(_ command: ChatComposerCommand) -> Bool {
        guard voiceInputTask == nil else { return true }
        if handleComposerCommand(command) { return true }
        guard command == .select else { return false }
        if globalStore.selectedModel != nil, !draft.content.isEmpty || !draft.files.isEmpty {
            submitDraft()
        }
        return true
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
                do {
                    try await chatService.compactContext(model: model, chat: chat)
                } catch is CancellationError {
                } catch {
                    requestError = error.localizedDescription
                }
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
              !chatService.isCompacting, !isRewinding else {
            return false
        }
        let activeChat = openChat()
        let message = Message(
            role: .user,
            chat: activeChat,
            content: content,
            files: files)
        Task {
            do {
                try await chatService.sendMessage(
                    model: model,
                    chat: activeChat,
                    message: message
                )
            } catch is CancellationError {
                // Stopped by the user or superseded by a newer request.
            } catch {
                requestError = error.localizedDescription
            }
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

    func rewindMessage(_ message: Message) {
        guard let chat, !isRewinding, !chatService.isCompacting else { return }
        isRewinding = true
        Task {
            defer { isRewinding = false }
            do {
                guard let restoredDraft = try await chatService.rewindMessage(chat: chat, message: message)
                else { return }
                draft = restoredDraft
                composerSelectionLocation = (draft.content as NSString).length
                slashCommandLocation = nil
            } catch {
                requestError = error.localizedDescription
            }
        }
    }

    func submitDraft() {
        guard voiceInputTask == nil else { return }
        if !submitMessage(content: draft.content, files: draft.files) {
            return
        }
        clearDraft()
    }

    /// Starts recording, or stops a recording so it is transcribed into the draft.
    func toggleVoiceInput() {
        if voiceInputTask == nil {
            startVoiceInput()
        } else if sttService.state == .recording {
            sttService.stop()
        }
    }

    /// Records until stopped and inserts the transcript into the draft at the cursor, where
    /// it can be edited before sending.
    func startVoiceInput() {
        guard voiceInputTask == nil, sttService.state == .idle,
              !chatService.isCompacting, !isRewinding,
              chatService.interactionCoordinator.pendingInteraction == nil else { return }
        voiceInputTask = Task {
            defer { voiceInputTask = nil }
            do {
                let text = try await sttService.record()
                try Task.checkCancellation()
                if !text.isEmpty {
                    insertIntoDraft(text)
                }
            } catch is CancellationError {
                // Cancelled by the user or by leaving the view.
            } catch {
                guard !Task.isCancelled else { return }
                voiceInputError = error.localizedDescription
            }
        }
    }

    /// Discards the recording; cancelling the task stops it.
    func cancelVoiceInput() {
        voiceInputTask?.cancel()
        if voiceInputTask != nil { sttService.cancel() }
    }

    func insertIntoDraft(_ text: String) {
        let content = draft.content as NSString
        let location = min(composerSelectionLocation, content.length)
        draft.content = content.replacingCharacters(in: NSRange(location: location, length: 0), with: text)
        composerSelectionLocation = location + (text as NSString).length
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
        inspectorTab = .files
        globalStore.isInspectorPresented = true
        return .handled
    }

    func resolvedPreviewURL(for path: String) -> URL? {
        guard let chat else { return nil }
        let baseURL = chat.project?.workingDirectory ?? chat.directory
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

        guard let project = chat.project else {
            return url
        }

        let roots = [project.workingDirectory, chat.directory].compactMap { $0 } + project.resources
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
        .background(.surface, in: RoundedRectangle(cornerRadius: 12))
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
            isSelected ? Color.accent.opacity(0.14) : Color.clear,
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

    @State private var detailHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allow this action?")
                .font(.headline)

            Text(request.title)
            if let detail = request.detail, !detail.isEmpty {
                // Show the whole command, patch, or script so the user knows what runs, but
                // scroll a long one instead of letting it push the buttons off screen.
                ScrollView {
                    Text(verbatim: detail)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            detailHeight = height
                        }
                }
                .frame(height: min(detailHeight, 240))
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                if request.toolName == ToolNames.runAppleScript {
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
    let onRewind: (Message) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                switch item {
                case .message(let message):
                    MessageView(message: message, onRewind: onRewind)
                        .scrollTargetLayout()
                case .assistantTurn(let turn):
                    AssistantTurnView(turn: turn)
                        .scrollTargetLayout()
                }
            }
        }
    }
}

#if DEBUG
#Preview(traits: .preview) {
    ChatView(chat: .preview)
        .frame(width: 760, height: 900)
}
#endif

// MARK: - Voice input

/// Samples microphone power with Vox's fast attack and slow release. Quiet input
/// settles to a static baseline; there is no synthetic idle animation.
struct VoiceLevelView: View {
    let sttService: STTService

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var levels = Array(repeating: 0.0, count: 64)

    var body: some View {
        HStack {
            if sttService.state == .recording {
                Canvas { context, size in
                    let count = min(levels.count, max(1, Int(size.width / 5)))
                    let spacing = size.width / Double(count)
                    for index in 0..<count {
                        let height = 2 + 26 * levels[levels.count - count + index]
                        let rect = CGRect(
                            x: Double(index) * spacing + (spacing - 3) / 2,
                            y: (size.height - height) / 2,
                            width: 3, height: height)
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 1.5),
                            with: .foreground)
                    }
                }
                .accessibilityLabel("Listening")
                .task {
                    var envelope = 0.0
                    while !Task.isCancelled {
                        let input = Double(sttService.level)
                        envelope += (input - envelope) * (input > envelope ? 0.85 : 0.45)
                        if envelope < 0.01 { envelope = 0 }
                        if envelope > 0 || levels.contains(where: { $0 > 0 }) {
                            if reduceMotion {
                                levels = Array(repeating: envelope, count: levels.count)
                            } else {
                                levels.removeFirst()
                                levels.append(envelope)
                            }
                        }
                        do {
                            try await Task.sleep(for: .seconds(1.0 / 30))
                        } catch { return }
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                if sttService.state == .transcribing {
                    Text("Transcribing")
                } else {
                    Text("Microphone")
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 36)
        .accessibilityElement(children: .combine)
    }
}
