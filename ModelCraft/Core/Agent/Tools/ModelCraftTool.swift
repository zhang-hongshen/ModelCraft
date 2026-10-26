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

/// Tools that operate ModelCraft itself: its settings, the page its window shows, and projects.
enum ModelCraftTool {

    static var allTools: [any ToolProtocol] {
        [readSettings, updateSettings, openPage, listProjects, createProject, updateProject]
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
        description: "Change ModelCraft's own settings, as the Settings window does: the appearance or theme (light mode, dark mode, or following the system), the interface language, whether tools load when needed, and notifications when scheduled tasks finish. Changes apply at once in every window and persist. Omit settings that stay unchanged. The permission mode cannot be changed here; only the user chooses it in the chat composer. Returns all settings as they now are.",
        parameters: [
            .optional("appearance", type: .string, description: "`system` follows the macOS appearance; `light` or `dark` always uses that one.", extraProperties: ["enum": ["system", "light", "dark"]]),
            .optional("language", type: .string, description: "The interface language, as a localization code from settings_read.", extraProperties: ["enum": languages]),
            .optional("load_tools_when_needed", type: .bool, description: "`true` starts each chat with essential tools and loads the others through search_tools; `false` offers every tool on every request. Applies from the next request."),
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
        description: "Show a page in ModelCraft's main window: an empty new chat, optionally in a project, or the Model Store, Downloaded Models, Connectors, or Scheduled Tasks page. The current conversation stays in the sidebar, where the user can return to it. Call it last in a turn: once the window shows another page, questions and approvals from this conversation are not seen until the user returns. Returns the page now shown.",
        parameters: [
            .required("page", type: .string, description: "`new_chat` opens an empty chat ready for a message; the others open the page of that name.", extraProperties: ["enum": OpenPageInput.Page.allCases.map(\.rawValue)]),
            .optional("project_id", type: .string, description: "`new_chat` only: the project_id from project_list or project_create of the project to start the chat in. Omit for a chat outside any project."),
        ]
    ) { input in
        try await MainActor.run {
            let store = GlobalStore.shared
            switch input.page {
            case .newChat:
                store.startNewChat(in: try input.projectID.map(project(id:)))
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
        description: "List the user's ModelCraft projects, newest first, with their project_id, title, working folder, number of reference files, and number of chats. This is read-only; use it to find the project_id that project_update and open_page need.",
        parameters: []
    ) { _ in
        try await MainActor.run {
            try ModelContainer.shared.mainContext.fetch(Project.fetch()).map(output)
        }
    }

    static let createProject = Tool<CreateProjectInput, ProjectOutput>(
        name: ToolNames.createProject,
        description: "Create an empty ModelCraft project with a title. It has no working folder or reference files; the user adds those by editing the project in the sidebar. Returns the new project with its project_id; to start working in it, open a new chat in it with open_page.",
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
        description: "Rename a ModelCraft project by the project_id from project_list or project_create. Its chats, working folder, and reference files are unchanged. Returns the project as it now is.",
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
            chatCount: project.chats.count)
    }
}

enum ModelCraftToolError: LocalizedError {
    case invalidAppearance(String)
    case invalidLanguage(String)
    case projectNotFound(String)
    case emptyTitle

    var errorDescription: String? {
        switch self {
        case .invalidAppearance(let value):
            "Unknown appearance `\(value)`. Use system, light, or dark."
        case .invalidLanguage(let value):
            "ModelCraft is not available in `\(value)`. Call settings_read for the available languages."
        case .projectNotFound(let id):
            "No project has the project_id \(id). Call project_list for the current identifiers."
        case .emptyTitle:
            "The project title is empty. Give a title with at least one visible character."
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
        case newChat = "new_chat"
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
    let chatCount: Int

    enum CodingKeys: String, CodingKey {
        case title
        case projectID = "project_id"
        case workingFolder = "working_folder"
        case referenceFileCount = "reference_file_count"
        case chatCount = "chat_count"
    }
}
