//
//  ModelCraftTool.swift
//  ModelCraft
//
//  Created by Hongshen on 25/10/26.
//

import Foundation
import SwiftData
import UserNotifications

import MLXLMCommon

/// Tools for ModelCraft settings, navigation, projects and conversation management.
enum ModelCraftTool {

    static func setProjectMemory(projectID: PersistentIdentifier) -> Tool<SetProjectMemoryInput, TaskToolOutput> {
        Tool(
            name: ToolNames.setProjectMemory,
            description: """
                Set this project's long-term memory shared by all its conversations. Save only durable project facts, conventions and user decisions relevant across tasks. Never copy conversation summaries, transient progress, task status, or execution checkpoints here. Change it only when the user asks to remember, correct or forget project knowledge; preserve unrelated facts when replacing. Returns the current memory.
                When the user designates a text reply as an example for future work, use read_current_thread to inspect the exchange. Match the assistant text and its position relative to the user's request. Save the task type and the returned thread_id and message_id of that reply. Quote any explicit reuse requirement verbatim. The reference alone suffices when no requirement was given. For a matching new task, read the saved message by both IDs before using the example.
                """,
            parameters: [
                .required("memory", type: .string, description: "Full replacement text including existing facts to keep. An empty string clears project memory."),
            ]
        ) { input in
            try await MainActor.run {
                let context = ModelContainer.shared.mainContext
                guard let project = context.model(for: projectID) as? Project else {
                    throw ModelCraftToolError.projectNotFound("current project")
                }
                project.memory = input.memory
                try context.save()
                return TaskToolOutput(content: project.memory)
            }
        }
    }

    static func searchProjectHistory(projectID: PersistentIdentifier, excluding threadID: UUID)
        -> Tool<ProjectHistoryInput, ProjectHistoryOutput> {
        Tool(
            name: ToolNames.searchProjectHistory,
            description: "Recall discussions and finished work from other chats in this project. Omit query for recent exchanges such as yesterday's idea, or search for a topic or filename. Returns dated, attributed original excerpts, attachment paths and successful file patch results, newest first. Use these as historical evidence, preserving tentative wording and later revisions. For surrounding messages or the complete version, use read_thread with the returned thread_id and message offset for context or message_id for the exact text. When project memory names an example for this task, read its saved IDs directly. Read the referenced file when the work is a file. If several versions fit, check the surrounding exchange for which revision the user meant. Read-only.",
            parameters: [
                .optional("query", type: .string, description: "A literal phrase, title fragment or attachment filename. Omit when only recency is known."),
                .optional("offset", type: .int, description: "Zero-based result offset. Defaults to 0. Use next_offset for older matches."),
            ]
        ) { input in
            try await MainActor.run {
                guard let project = ModelContainer.shared.mainContext.model(for: projectID) as? Project else {
                    throw ModelCraftToolError.projectNotFound("current project")
                }
                let query = input.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                var matches: [(thread: Thread, offset: Int, message: Message, start: String.Index)] = []
                for thread in project.threads where thread.id != threadID {
                    try Task.checkCancellation()
                    let titleMatches = thread.title?.localizedCaseInsensitiveContains(query) == true
                    for (offset, message) in thread.conversation.enumerated() where message.status == .generated {
                        guard message.role == .user || message.role == .assistant ||
                                (message.role == .tool && message.toolCall?.function.name == ToolNames.applyPatch),
                              !message.content.isEmpty || !message.files.isEmpty else { continue }
                        let range = query.isEmpty ? nil : message.content.localizedStandardRange(of: query)
                        guard query.isEmpty || range != nil || titleMatches ||
                                message.files.contains(where: { $0.lastPathComponent.localizedCaseInsensitiveContains(query) })
                        else { continue }
                        let start = range.flatMap {
                            message.content.index($0.lowerBound, offsetBy: -100, limitedBy: message.content.startIndex)
                        } ?? message.content.startIndex
                        matches.append((thread, offset, message, start))
                    }
                }
                matches.sort {
                    if $0.message.createdAt == $1.message.createdAt {
                        return $0.message.id.uuidString < $1.message.id.uuidString
                    }
                    return $0.message.createdAt > $1.message.createdAt
                }
                let offset = max(0, input.offset ?? 0)
                let page = matches.dropFirst(offset).prefix(8)
                return ProjectHistoryOutput(matches: page.map { match in
                    let message = match.message
                    var paths = message.files.map(\.path)
                    if message.role == .tool, let call = message.toolCall {
                        let directory = project.workingDirectory ?? match.thread.directory
                        for change in call.patchFileChanges where change.action == .edit {
                            let url = URL(fileURLWithPath: change.path, relativeTo: directory).standardizedFileURL
                            if FileManager.default.fileExists(atPath: url.path) { paths.append(url.path) }
                        }
                    }
                    let excerpt = message.content[match.start...].prefix(600)
                    return ProjectHistoryMatch(
                        thread_id: match.thread.id, message_id: message.id, title: match.thread.title, message_offset: match.offset,
                        date: message.createdAt.formatted(), role: String(describing: message.role),
                        excerpt: String(excerpt),
                        truncated: excerpt.startIndex != message.content.startIndex || excerpt.endIndex != message.content.endIndex,
                        files: paths)
                }, next_offset: offset + page.count < matches.count ? offset + page.count : nil)
            }
        }
    }

    static var allTools: [any ToolProtocol] {
        [readSettings, updateSettings, openPage, listProjects, createProject, updateProject,
         listThreads, readCurrentThread, readThread, createThread, updateThread, openThread, deleteThread, deleteThreadMessages]
    }

    static let listThreads = Tool<ThreadListInput, ThreadListOutput>(
        name: ToolNames.listThreads,
        description: "List ModelCraft chats, newest first, optionally filtered by title and project_id from list_projects. Returns stable thread_id values, titles, project IDs, message counts and execution state, with next_offset for pagination. Read-only; use read_thread to inspect messages before changing a chat.",
        parameters: [
            .optional("query", type: .string, description: "Case-insensitive title substring. Omit for all titles."),
            .optional("project_id", type: .string, description: "Only chats in this project from list_projects. Omit for all projects and standalone chats."),
            .optional("offset", type: .int, description: "Zero-based offset; defaults to 0."),
            .optional("limit", type: .int, description: "Page size, 1–100; defaults to 20."),
        ]
    ) { input in
        try await MainActor.run {
            let project = try input.projectID.map(ModelCraftTool.project(id:))
            let threads = try ModelContainer.shared.mainContext.fetch(
                FetchDescriptor<Thread>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
                .filter { thread in
                    (project == nil || thread.project?.id == project?.id)
                        && (input.query.map { (thread.title ?? "").localizedCaseInsensitiveContains($0) } ?? true)
                }
            let offset = max(0, input.offset ?? 0)
            let page = Array(threads.dropFirst(offset).prefix(min(100, max(1, input.limit ?? 20))))
            return ThreadListOutput(threads: page.map(ThreadOutput.init),
                                    next_offset: offset + page.count < threads.count ? offset + page.count : nil)
        }
    }

    @TaskLocal static var currentThreadID: UUID?

    static let readCurrentThread = Tool<CurrentThreadReadInput, ThreadReadOutput>(
        name: ToolNames.readCurrentThread,
        description: "Read recent messages in the chat making this call. Use this to identify the exact reply the user means by 'this version'. Returns the thread_id and ordered messages with their message_id, role, text and attachment URLs. For a truncated reply, use read_thread with the returned IDs and character_offset to continue. Read-only.",
        parameters: [
            .optional("offset", type: .int, description: "Zero-based message offset. Omit for the most recent page."),
            .optional("limit", type: .int, description: "Messages per page, 1–50; defaults to 20."),
        ]
    ) { input in
        try await MainActor.run {
            guard let currentThreadID else { throw ModelCraftToolError.threadNotFound("current chat") }
            let thread = try ModelCraftTool.thread(id: currentThreadID.uuidString)
            return try readMessages(in: thread, offset: input.offset, limit: input.limit)
        }
    }

    static let readThread = Tool<ThreadReadInput, ThreadReadOutput>(
        name: ToolNames.readThread,
        description: "Read a ModelCraft chat using thread_id from list_thread, search_project_history or create_thread. Returns its metadata and messages in conversation order, including message_id, role, text and attachment URLs. Read-only. Message text is capped at 8000 characters per message with a truncated flag. For a designated project example, pass the saved thread_id and message_id to read exactly that revision. If missing, report that the example is unavailable. For truncated text, repeat the same message_id (or offset with limit 1) and advance character_offset by the number of characters returned. next_offset pages the history.",
        parameters: [
            .required("thread_id", type: .string, description: "Stable chat identifier from project memory, read_current_thread, list_thread, search_project_history or create_thread."),
            .optional("message_id", type: .string, description: "Exact message UUID within this chat. Selects only this message, ignoring offset and limit."),
            .optional("offset", type: .int, description: "Zero-based message offset; defaults to 0."),
            .optional("character_offset", type: .int, description: "Skip this many Swift Characters in the first message of the page. Defaults to 0."),
            .optional("limit", type: .int, description: "Messages per page, 1–50; defaults to 20."),
        ]
    ) { input in
        try await MainActor.run {
            let thread = try ModelCraftTool.thread(id: input.thread_id)
            return try readMessages(in: thread, messageID: input.message_id, offset: input.offset ?? 0,
                                    limit: input.limit, characterOffset: input.character_offset)
        }
    }

    @MainActor
    private static func readMessages(in thread: Thread, messageID: String? = nil, offset: Int?,
                                     limit requestedLimit: Int?, characterOffset: Int? = nil) throws -> ThreadReadOutput {
        let limit = min(50, max(1, requestedLimit ?? 20))
        let history = thread.conversation
        let page: ArraySlice<Message>
        let nextOffset: Int?
        if let id = messageID {
            guard let uuid = UUID(uuidString: id), let index = history.firstIndex(where: { $0.id == uuid }) else {
                throw ModelCraftToolError.messageNotFound(id)
            }
            page = history[index...index]
            nextOffset = nil
        } else {
            let offset = max(0, offset ?? (history.count - limit))
            page = history.dropFirst(offset).prefix(limit)
            nextOffset = page.endIndex < history.count ? page.endIndex : nil
        }
        return ThreadReadOutput(thread: ThreadOutput(thread), messages: page.enumerated().map { index, message in
            let text = message.content.dropFirst(index == 0 ? max(0, characterOffset ?? 0) : 0)
            return ThreadMessageOutput(message_id: message.id.uuidString, role: String(describing: message.role),
                                       content: String(text.prefix(8000)), truncated: text.count > 8000,
                                       files: message.files.map(\.absoluteString))
        }, next_offset: nextOffset)
    }

    static let createThread = Tool<ThreadCreateInput, ThreadOutput>(
        name: ToolNames.createThread,
        description: "Create and persist an empty ModelCraft chat without sending a message or changing the visible page. Optionally place it in a project from list_projects. Returns thread_id for read_thread, update_thread and open_thread. Does not start inference.",
        parameters: [
            .required("title", type: .string, description: "Nonempty chat title shown in the sidebar."),
            .optional("project_id", type: .string, description: "Project from list_projects. Omit for a standalone chat; the project determines tool file access."),
        ]
    ) { input in
        try await MainActor.run {
            let thread = Thread(title: try title(input.title), project: try input.projectID.map(project(id:)))
            let context = ModelContainer.shared.mainContext
            context.insert(thread)
            try context.save()
            return ThreadOutput(thread)
        }
    }

    static let updateThread = Tool<ThreadRenameInput, ThreadOutput>(
        name: ToolNames.updateThread,
        description: "Rename a ModelCraft chat using thread_id from list_thread. Returns its updated metadata. Reuses the sidebar rename operation; does not change messages, project, permissions or navigation.",
        parameters: [
            .required("thread_id", type: .string, description: "Chat identifier from list_thread or create_thread."),
            .required("title", type: .string, description: "Nonempty new chat title."),
        ]
    ) { input in
        try await MainActor.run {
            let thread = try ModelCraftTool.thread(id: input.thread_id)
            try thread.rename(to: title(input.title))
            return ThreadOutput(thread)
        }
    }

    static let openThread = Tool<ThreadIDInput, ThreadOutput>(
        name: ToolNames.openThread,
        description: "Open an existing ModelCraft chat using thread_id from list_thread. Returns the opened chat metadata. Call last in the turn: navigating away hides questions and approval prompts from the current chat until the user returns. Does not send a message or start inference.",
        parameters: [.required("thread_id", type: .string, description: "Chat identifier from list_thread or create_thread.")]
    ) { input in
        try await MainActor.run {
            let thread = try ModelCraftTool.thread(id: input.thread_id)
            GlobalStore.shared.currentTab = .thread(thread)
            return ThreadOutput(thread)
        }
    }

    static let deleteThread = Tool<ThreadIDInput, ThreadDeletionOutput>(
        name: ToolNames.deleteThread,
        description: "Permanently delete a ModelCraft chat, its messages, originating tasks and thread working folder. Read read_thread first to verify the target. Requires fresh approval in Auto/Ask mode (Full Access skips approval); blocked in Read Only and unattended runs. Executing chats cannot be deleted, including this running chat. Returns the deleted thread_id. Shared attachments are collected later when unreferenced.",
        parameters: [.required("thread_id", type: .string, description: "Exact chat identifier verified with read_thread. Deletion cannot be undone.")]
    ) { input in
        try await MainActor.run {
            let thread = try ModelCraftTool.thread(id: input.thread_id)
            try requireIdle(thread)
            try thread.deleteFromApp()
            return ThreadDeletionOutput(thread_id: input.thread_id, deleted_messages: nil)
        }
    }

    static let deleteThreadMessages = Tool<ThreadMessagesDeleteInput, ThreadDeletionOutput>(
        name: ToolNames.deleteThreadMessages,
        description: "Permanently delete a user message and all following messages in an idle ModelCraft chat, preserving complete earlier tool-call turns. Use read_thread to verify the user message_id and affected history first. Invalidates affected task checkpoints and stale summaries through the same model operation used by resend. Requires fresh approval in Auto/Ask mode (Full Access skips approval); blocked in Read Only and unattended runs. Executing chats cannot be edited. Returns the deleted message count; does not resend or start inference.",
        parameters: [
            .required("thread_id", type: .string, description: "Idle chat identifier verified with read_thread."),
            .required("message_id", type: .string, description: "User message from read_thread. This message and the entire following history will be deleted; cannot be undone."),
        ]
    ) { input in
        try await MainActor.run {
            let thread = try ModelCraftTool.thread(id: input.thread_id)
            try requireIdle(thread)
            let history = thread.conversation
            guard let index = history.firstIndex(where: { $0.id.uuidString == input.message_id && $0.role == .user }) else {
                throw ModelCraftToolError.invalidMessage
            }
            let removed = Array(history[index...])
            thread.deleteMessages(removed)
            thread.discardStaleSummary()
            try ModelContainer.shared.mainContext.save()
            return ThreadDeletionOutput(thread_id: input.thread_id, deleted_messages: removed.count)
        }
    }

    @MainActor
    private static func thread(id: String) throws -> Thread {
        guard let uuid = UUID(uuidString: id),
              let thread = try ModelContainer.shared.mainContext.fetch(FetchDescriptor<Thread>(
                predicate: #Predicate<Thread> { $0.id == uuid })).first else {
            throw ModelCraftToolError.threadNotFound(id)
        }
        return thread
    }

    @MainActor
    private static func requireIdle(_ thread: Thread) throws {
        let affectedTickets = thread.tickets + thread.messages.flatMap(\.tickets)
        guard !thread.isGenerating, thread.activeTicket?.isExecuting != true,
              !affectedTickets.contains(where: { $0.isExecuting }) else {
            throw ModelCraftToolError.threadExecuting
        }
    }

    /// Interface languages the app bundle is localized in.
    private static let languages = Bundle.main.localizations.filter { $0 != "Base" }

    static let readSettings = Tool<ReadSettingsInput, SettingsOutput>(
        name: ToolNames.readSettings,
        description: "Read ModelCraft's own settings: the appearance or theme (light, dark, or following the system), the interface language with the languages available, whether tools load when needed, whether scheduled-task notifications are on, and the permission mode for tool approval. This is read-only.",
        parameters: []
    ) { _ in
        await MainActor.run { settingsOutput() }
    }

    static let updateSettings = Tool<UpdateSettingsInput, SettingsOutput>(
        name: ToolNames.updateSettings,
        description: "Change ModelCraft's own settings, as the Settings window does: the appearance or theme (light mode, dark mode, or following the system), the interface language, whether tools load when needed, and notifications when scheduled tasks finish. Changes apply at once in every window and persist. Omit settings that stay unchanged. The permission mode cannot be changed here; only the user chooses it in the thread composer. Returns all settings as they now are.",
        parameters: [
            .optional("appearance", type: .string, description: "`system` follows the macOS appearance; `light` or `dark` always uses that one.", extraProperties: ["enum": ["system", "light", "dark"]]),
            .optional("language", type: .string, description: "The interface language, as a localization code from read_settings.", extraProperties: ["enum": languages]),
            .optional("load_tools_when_needed", type: .bool, description: "`true` starts each thread with essential tools and loads the others through search_tools; `false` offers every tool on every request. Applies from the next request."),
            .optional("notify_when_scheduled_tasks_finish", type: .bool, description: "`true` shows a macOS notification when a scheduled task's run completes or fails. Turning it on asks macOS for notification permission if the user has not answered yet."),
        ]
    ) { input in
        try await MainActor.run {
            let appearance = try input.appearance.map { value in
                guard let appearance = Appearance(rawValue: value) else {
                    throw ModelCraftToolError.invalidAppearance(value)
                }
                return appearance
            }
            if let language = input.language, !languages.contains(language) {
                throw ModelCraftToolError.invalidLanguage(language)
            }
            let settings = UserSettings.shared
            if let appearance { settings.appearance = appearance }
            if let language = input.language { settings.language = language }
            if let value = input.loadToolsWhenNeeded { settings.loadToolsWhenNeeded = value }
            if let value = input.notifyWhenScheduledTasksFinish {
                settings.notifyWhenScheduledTasksFinish = value
            }
        }
        if input.notifyWhenScheduledTasksFinish == true {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        }
        return await MainActor.run { settingsOutput() }
    }

    static let openPage = Tool<OpenPageInput, OpenPageOutput>(
        name: ToolNames.openPage,
        description: "Show a page in ModelCraft's main window: an empty new thread, optionally in a project, or the Model Store, Downloaded Models, Connectors, or Scheduled Tasks page. The current conversation stays in the sidebar, where the user can return to it. Call it last in a turn: once the window shows another page, questions and approvals from this conversation are not seen until the user returns. Returns the page now shown.",
        parameters: [
            .required("page", type: .string, description: "`new_thread` opens an empty thread ready for a message; the others open the page of that name.", extraProperties: ["enum": OpenPageInput.Page.allCases.map(\.rawValue)]),
            .optional("project_id", type: .string, description: "`new_thread` only: the project_id from list_projects or create_project of the project to start the thread in. Omit for a thread outside any project."),
        ]
    ) { input in
        try await MainActor.run {
            let store = GlobalStore.shared
            switch input.page {
            case .newThread:
                store.startNewThread(in: try input.projectID.map(project(id:)))
            case .modelStore:
                store.currentTab = .modelStore
            case .downloadedModels:
                store.currentTab = .downloadedModels
            case .connectors:
                store.currentTab = .connectors
            case .scheduledTasks:
                store.currentTab = .schedules
            }
            return OpenPageOutput(page: input.page.rawValue)
        }
    }

    static let listProjects = Tool<ListProjectsInput, [ProjectOutput]>(
        name: ToolNames.listProjects,
        description: "List the user's ModelCraft projects, newest first, with their project_id, title, working folder, number of reference files, and number of threads. This is read-only; use it to find the project_id that update_project and open_page need.",
        parameters: []
    ) { _ in
        try await MainActor.run {
            try ModelContainer.shared.mainContext.fetch(Project.fetch()).map(output)
        }
    }

    static let createProject = Tool<CreateProjectInput, ProjectOutput>(
        name: ToolNames.createProject,
        description: "Create an empty ModelCraft project with a title. It has no working folder or reference files; the user adds those by editing the project in the sidebar. Returns the new project with its project_id; to start working in it, open a new thread in it with open_page.",
        parameters: [
            .required("title", type: .string, description: "The project's name as shown in the sidebar."),
        ]
    ) { input in
        try await MainActor.run {
            let project = Project(title: try title(input.title))
            ModelContainer.shared.mainContext.persist(project)
            return output(project)
        }
    }

    static let updateProject = Tool<UpdateProjectInput, ProjectOutput>(
        name: ToolNames.updateProject,
        description: "Rename a ModelCraft project by the project_id from list_projects or create_project. Its threads, working folder, and reference files are unchanged. Returns the project as it now is.",
        parameters: [
            .required("project_id", type: .string, description: "The project_id of the project to rename."),
            .required("title", type: .string, description: "The project's new name as shown in the sidebar."),
        ]
    ) { input in
        try await MainActor.run {
            let project = try ModelCraftTool.project(id: input.projectID)
            project.title = try title(input.title)
            try ModelContainer.shared.mainContext.save()
            return output(project)
        }
    }
}

struct SetProjectMemoryInput: Codable { let memory: String }

// MARK: - Helpers

extension ModelCraftTool {

    @MainActor
    private static func settingsOutput() -> SettingsOutput {
        let settings = UserSettings.shared
        let permissionMode = UserDefaults.standard.string(forKey: UserDefaults.toolPermissionMode)
            .flatMap(ToolPermissionMode.init(rawValue:)) ?? UserDefaultSettings.toolPermissionMode
        return SettingsOutput(
            appearance: settings.appearance.rawValue,
            language: settings.language,
            availableLanguages: languages.map { code in
                LanguageOutput(
                    code: code,
                    name: Locale(identifier: code).localizedString(forLanguageCode: code) ?? code)
            },
            loadToolsWhenNeeded: settings.loadToolsWhenNeeded,
            notifyWhenScheduledTasksFinish: settings.notifyWhenScheduledTasksFinish,
            permissionMode: permissionMode.rawValue)
    }

    @MainActor
    private static func project(id: String) throws -> Project {
        guard let uuid = UUID(uuidString: id),
              let project = try ModelContainer.shared.mainContext.fetch(FetchDescriptor<Project>(
                predicate: #Predicate<Project> { $0.id == uuid })).first
        else {
            throw ModelCraftToolError.projectNotFound(id)
        }
        return project
    }

    private static func title(_ value: String) throws -> String {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ModelCraftToolError.emptyTitle }
        return title
    }

    @MainActor
    private static func output(_ project: Project) -> ProjectOutput {
        ProjectOutput(
            projectID: project.id.uuidString,
            title: project.title,
            workingFolder: project.workingDirectory?.path,
            referenceFileCount: project.resources.count,
            threadCount: project.threads.count)
    }
}

enum ModelCraftToolError: LocalizedError {
    case invalidAppearance(String)
    case invalidLanguage(String)
    case projectNotFound(String)
    case threadNotFound(String)
    case threadExecuting
    case invalidMessage
    case messageNotFound(String)
    case emptyTitle

    var errorDescription: String? {
        switch self {
        case .invalidAppearance(let value):
            "Unknown appearance `\(value)`. Use system, light, or dark."
        case .invalidLanguage(let value):
            "ModelCraft is not available in `\(value)`. Call read_settings for the available languages."
        case .projectNotFound(let id):
            "No project has the project_id \(id). Call list_projects for the current identifiers."
        case .threadNotFound(let id):
            "No chat has thread_id \(id). Call list_thread for current identifiers."
        case .threadExecuting:
            "This chat or a task referencing its messages is executing. Stop it in the app before deleting history."
        case .messageNotFound(let id):
            "Message \(id) is unavailable in this chat."
        case .invalidMessage:
            "No user message has this message_id in the chat. Call read_thread to verify the target."
        case .emptyTitle:
            "The title is empty. Give a title with at least one visible character."
        }
    }
}

struct ReadSettingsInput: Codable {}

struct UpdateSettingsInput: Codable {
    let appearance: String?
    let language: String?
    let loadToolsWhenNeeded: Bool?
    let notifyWhenScheduledTasksFinish: Bool?

    enum CodingKeys: String, CodingKey {
        case appearance, language
        case loadToolsWhenNeeded = "load_tools_when_needed"
        case notifyWhenScheduledTasksFinish = "notify_when_scheduled_tasks_finish"
    }
}

struct LanguageOutput: Codable {
    let code: String
    let name: String
}

struct SettingsOutput: Codable {
    let appearance: String
    let language: String
    let availableLanguages: [LanguageOutput]
    let loadToolsWhenNeeded: Bool
    let notifyWhenScheduledTasksFinish: Bool
    let permissionMode: String

    enum CodingKeys: String, CodingKey {
        case appearance, language
        case availableLanguages = "available_languages"
        case loadToolsWhenNeeded = "load_tools_when_needed"
        case notifyWhenScheduledTasksFinish = "notify_when_scheduled_tasks_finish"
        case permissionMode = "permission_mode"
    }
}

struct OpenPageInput: Codable {
    enum Page: String, Codable, CaseIterable {
        case newThread = "new_thread"
        case modelStore = "model_store"
        case downloadedModels = "downloaded_models"
        case connectors
        case scheduledTasks = "scheduled_tasks"
    }

    let page: Page
    let projectID: String?

    enum CodingKeys: String, CodingKey {
        case page
        case projectID = "project_id"
    }
}

struct OpenPageOutput: Codable {
    let page: String
}

struct ListProjectsInput: Codable {}

struct CreateProjectInput: Codable {
    let title: String
}

struct UpdateProjectInput: Codable {
    let projectID: String
    let title: String

    enum CodingKeys: String, CodingKey {
        case title
        case projectID = "project_id"
    }
}

struct ProjectOutput: Codable {
    let projectID: String
    let title: String
    let workingFolder: String?
    let referenceFileCount: Int
    let threadCount: Int

    enum CodingKeys: String, CodingKey {
        case title
        case projectID = "project_id"
        case workingFolder = "working_folder"
        case referenceFileCount = "reference_file_count"
        case threadCount = "thread_count"
    }
}

struct ProjectHistoryInput: Codable {
    let query: String?
    let offset: Int?
}

struct ProjectHistoryMatch: Codable {
    let thread_id: UUID
    let message_id: UUID
    let title: String?
    let message_offset: Int
    let date: String
    let role: String
    let excerpt: String
    let truncated: Bool
    let files: [String]
}

struct ProjectHistoryOutput: Codable {
    let matches: [ProjectHistoryMatch]
    let next_offset: Int?
}

struct ThreadListInput: Codable {
    let query: String?
    let projectID: String?
    let offset: Int?
    let limit: Int?
    enum CodingKeys: String, CodingKey {
        case query, offset, limit
        case projectID = "project_id"
    }
}
struct ThreadListOutput: Codable {
    let threads: [ThreadOutput]
    let next_offset: Int?
}
struct ThreadIDInput: Codable { let thread_id: String }
struct CurrentThreadReadInput: Codable {
    let offset: Int?
    let limit: Int?
}

struct ThreadReadInput: Codable {
    let message_id: String?
    let character_offset: Int?
    let thread_id: String
    let offset: Int?
    let limit: Int?
}
struct ThreadRenameInput: Codable { let thread_id: String; let title: String }
struct ThreadCreateInput: Codable {
    let title: String
    let projectID: String?
    enum CodingKeys: String, CodingKey {
        case title
        case projectID = "project_id"
    }
}
struct ThreadMessagesDeleteInput: Codable { let thread_id: String; let message_id: String }
struct ThreadDeletionOutput: Codable { let thread_id: String; let deleted_messages: Int? }
struct ThreadMessageOutput: Codable {
    let message_id: String
    let role: String
    let content: String
    let truncated: Bool
    let files: [String]
}
struct ThreadReadOutput: Codable {
    let thread: ThreadOutput
    let messages: [ThreadMessageOutput]
    let next_offset: Int?
}
struct ThreadOutput: Codable {
    let thread_id: String
    let title: String?
    let project_id: String?
    let message_count: Int
    let is_executing: Bool

    @MainActor init(_ thread: Thread) {
        thread_id = thread.id.uuidString
        title = thread.title
        project_id = thread.project?.id.uuidString
        message_count = thread.messages.count
        is_executing = thread.isGenerating || thread.activeTicket?.isExecuting == true
            || thread.tickets.contains { $0.isExecuting }
    }
}
