//
//  ChatView.swift
//  ModelCraft
//
//  Created by Hongshen on 23/3/2024.
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
    @State private var composerHeight: CGFloat = 0
    @State private var skillCommands: [ChatCommand] = []
    @State private var selectedCommand: ChatCommand = .compact
    @State private var composerSelectionLocation = 0
    @State private var slashCommandLocation: Int?
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
            .onChange(of: slashCommandLocation) {
                if slashCommandLocation != nil {
                    reloadCommands()
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
            if let pendingInteraction = chatService.interactionCoordinator.pendingInteraction {
                UserInteractionRequestView(
                    pendingInteraction: pendingInteraction,
                    onSubmitUserInput: chatService.interactionCoordinator.submitUserInput,
                    onResolveApproval: chatService.interactionCoordinator.resolveApproval)
                .id(pendingInteraction.id)
            }

            if isCommandPalettePresented {
                ChatCommandPalette(
                    skillCommands: skillCommands,
                    selectedCommand: selectedCommand,
                    isEnabled: isCommandEnabled,
                    onSelect: runCommand)
            }

            ChatInputView(
                userInput: draft,
                skillNames: skillCommands.compactMap(\.skillName),
                selectionLocation: $composerSelectionLocation,
                slashCommandLocation: $slashCommandLocation,
                onCommand: handleComposerCommand,
                trailing: {
                    HStack {
                        if let usage = contextUsage {
                            ProgressView(value: usage.fraction)
                                .controlSize(.small)
                                .help(String(localized: "\(usage.usedTokens.formatted()) of \(usage.totalTokens.formatted()) context tokens"))
                                .accessibilityLabel("Context window usage")
                                .accessibilityValue(Text(usage.fraction.formatted(.percent.precision(.fractionLength(0)))))
                        }

                        ModelPickerButton()

                        if chatService.isCompacting {
                            ProgressView()
                                .controlSize(.small)
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
        let activeChat: Chat
        if let chat = chat {
            activeChat = chat
        } else {
            activeChat = chatService.createChat(project: globalStore.newChatProject)
            globalStore.currentTab = .chat(activeChat)
            globalStore.newChatProject = nil
        }
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

    func submitDraft() {
        if !submitMessage(content: draft.content, files: draft.files) {
            return
        }
        clearDraft()
    }
    
    func clearDraft() {
        draft.content = ""
        draft.files = []
        composerSelectionLocation = 0
        slashCommandLocation = nil
    }

    var contextUsage: ContextWindowUsage? {
        guard let model = globalStore.selectedModel,
              let message = chat?.sortedMessages.reversed().first(where: {
                  $0.promptTokenCount != nil && $0.generationTokenCount != nil
              }),
              let promptTokenCount = message.promptTokenCount,
              let generationTokenCount = message.generationTokenCount else {
            return nil
        }
        return ContextWindowUsage(
            usedTokens: promptTokenCount + generationTokenCount,
            totalTokens: model.contextWindow)
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
    let onResolveApproval: (Bool) -> Void

    var body: some View {
        VStack {
            switch pendingInteraction {
            case .userInput(let pendingUserInput):
                UserInputRequestView(
                    pendingUserInput: pendingUserInput,
                    onConfirm: onSubmitUserInput)
            case .approval(let pendingApproval):
                ToolApprovalRequestView(
                    request: pendingApproval.request,
                    onResolve: onResolveApproval)
            }
        }
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.separator.opacity(0.5))
        }
    }
}

private struct UserInputRequestView: View {

    let pendingUserInput: UserInteractionCoordinator.PendingUserInput
    let onConfirm: ([UserInputAnswer]) -> Void

    @State private var form = UserInputFormModel()
    @State private var fileImporterPresented = false
    @State private var importingFieldID: String?
    @State private var fileImportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(pendingUserInput.request.fields) { field in
                        UserInputFieldView(
                            field: field,
                            form: form,
                            onChooseFiles: presentFileImporter)
                    }
                }
            }
            .frame(maxHeight: 360)

            if let fileImportError {
                Text(fileImportError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Confirm") {
                    onConfirm(form.answers(for: pendingUserInput.request.fields))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!form.isComplete(fields: pendingUserInput.request.fields))
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

    private var importingField: UserInputField? {
        pendingUserInput.request.fields.first { $0.id == importingFieldID }
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
    let onResolve: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allow this action?")
                .font(.headline)

            Text(request.title)
            if let detail = request.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Don't Allow") {
                    onResolve(false)
                }
                Button("Allow for This Task") {
                    onResolve(true)
                }
                .buttonStyle(.borderedProminent)
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

    func isComplete(fields: [UserInputField]) -> Bool {
        fields.allSatisfy { !values(for: $0).isEmpty }
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
