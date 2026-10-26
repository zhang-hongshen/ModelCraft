//
//  ToolCall.swift
//  ModelCraft
//
//  Created by Hongshen on 21/1/26.
//

import Foundation
import MLXLMCommon
import SwiftUI


struct ToolNames {
    // MARK: User Input Tool
    static let requestUserInput = "request_user_input"

    // MARK: File Tool
    static let readFile = "read_file"
    static let applyPatch = "apply_patch"
    static let listDirectory = "list_directory"

    // MARK: Command Tool
    static let executeCommand = "execute_command"

    // MARK: Search Tool
    static let searchMap = "search_map"
    static let searchProject = "search_project"
    static let searchRelevantDocuments = "search_relevant_documents"
    static let webFetch = "web_fetch"

    // MARK: Screen Control Tool
    static let appScreenshot = "app_screenshot"
    static let appZoom = "app_zoom"

    // MARK: Skill Tool
    static let activateSkill = "activate_skill"

    // MARK: Tool Search
    static let searchTools = "search_tools"

    // MARK: Image Tool
    static let textToImage = "text_to_image"

    // MARK: Video Tool
    static let textToVideo = "text_to_video"

    // MARK: Audio Tool
    static let textToAudio = "text_to_audio"

    // MARK: Computer Use Tool
    static let listApps = "list_apps"
    static let openApp = "open_app"
    static let appFind = "app_find"
    static let appClick = "app_click"
    static let appType = "app_type"
    static let appKey = "app_key"
    static let appScroll = "app_scroll"
    static let appDrag = "app_drag"
    static let appMenu = "app_menu"

    // MARK: Native Application Tool
    static let searchNotes = "notes_search"
    static let readNote = "notes_read"
    static let createNote = "notes_create"
    static let updateNote = "notes_update"
    static let searchCalendar = "calendar_search"
    static let readCalendarEvent = "calendar_read"
    static let createCalendarEvent = "calendar_create"
    static let updateCalendarEvent = "calendar_update"
    static let searchReminders = "reminders_search"
    static let readReminder = "reminders_read"
    static let createReminder = "reminders_create"
    static let updateReminder = "reminders_update"
    static let searchMail = "mail_search"
    static let readMail = "mail_read"
    static let createMailDraft = "mail_create_draft"
    static let runAppleScript = "run_applescript"

    // MARK: Schedule Tool
    static let createSchedule = "schedule_create"
    static let listSchedules = "schedule_list"
    static let updateSchedule = "schedule_update"
    static let deleteSchedule = "schedule_delete"
    static let listWorkdays = "workdays_list"
    static let setWorkday = "workdays_set"

    // MARK: ModelCraft Tool
    static let readSettings = "settings_read"
    static let updateSettings = "settings_update"
    static let openPage = "open_page"
    static let listProjects = "project_list"
    static let createProject = "project_create"
    static let updateProject = "project_update"
}

typealias VideoGenerationProgressHandler = @MainActor @Sendable (LTXVideoProgress) -> Void
typealias ImageGenerationProgressHandler = @MainActor @Sendable (StableDiffusionProgress) -> Void

enum ToolExecutionProgressReporter {
    @TaskLocal static var videoGeneration: VideoGenerationProgressHandler?
    @TaskLocal static var imageGeneration: ImageGenerationProgressHandler?
}

struct ToolApprovalRequest: Sendable {
    let toolName: String
    let title: String
    let detail: String?

    /// AppleScript can do anything the app can, so every script needs a fresh decision.
    var allowsAlways: Bool {
        toolName != ToolNames.runAppleScript
    }
}

enum ToolApprovalDecision: Sendable {
    case deny
    case allowOnce
    case alwaysAllow
}

enum PatchFileAction: Hashable {
    case edit
    case delete
}

struct PatchFileChange: Identifiable, Hashable {
    let path: String
    let action: PatchFileAction

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
}

extension StableDiffusionProgress {
    var localizedDescription: String {
        switch self {
        case .downloading(let percent):
            let percentage = (Double(percent) / 100).formatted(
                .percent.precision(.fractionLength(0)))
            return String(localized: "Downloading image model \(percentage)")
        case .loading:
            return String(localized: "Loading image model...")
        case .generating(let completed, let total):
            guard total > 0 else { return String(localized: "Generating image") }
            let percentage = (Double(completed) / Double(total)).formatted(
                .percent.precision(.fractionLength(0)))
            return String(localized: "Generating image \(percentage)")
        case .decoding:
            return String(localized: "Decoding image...")
        case .saving:
            return String(localized: "Saving image...")
        }
    }

    var storedValue: String {
        switch self {
        case .downloading(let percent):
            "image:downloading:\(percent)"
        case .loading:
            "image:loading"
        case .generating(let completed, let total):
            "image:generating:\(completed):\(total)"
        case .decoding:
            "image:decoding"
        case .saving:
            "image:saving"
        }
    }

    init?(storedValue: String) {
        let components = storedValue.split(separator: ":")
        guard components.first == "image" else { return nil }

        switch components.dropFirst().first {
        case "downloading":
            guard components.count == 3,
                  let percent = Int(components[2])
            else { return nil }
            self = .downloading(percent: percent)
        case "loading":
            self = .loading
        case "generating":
            guard components.count == 4,
                  let completed = Int(components[2]),
                  let total = Int(components[3])
            else { return nil }
            self = .generating(completed: completed, total: total)
        case "decoding":
            self = .decoding
        case "saving":
            self = .saving
        default:
            return nil
        }
    }
}

extension LTXVideoProgress {
    var localizedDescription: String {
        switch self {
        case .preparing:
            return String(localized: "Preparing...")
        case .generating(let completed, let total):
            guard total > 0 else { return String(localized: "Preparing...") }
            let percentage = (Double(completed) / Double(total)).formatted(
                .percent.precision(.fractionLength(0...1)))
            return String(
                format: String(localized: "Generating video %@"),
                percentage)
        case .decoding:
            return String(localized: "Decoding...")
        case .writing:
            return String(localized: "Writing video...")
        }
    }

    var storedValue: String {
        switch self {
        case .preparing:
            "video:preparing"
        case .generating(let completed, let total):
            "video:generating:\(completed):\(total)"
        case .decoding:
            "video:decoding"
        case .writing:
            "video:writing"
        }
    }

    init?(storedValue: String) {
        let components = storedValue.split(separator: ":")
        guard components.first == "video" else { return nil }

        switch components.dropFirst().first {
        case "preparing":
            self = .preparing
        case "generating":
            guard components.count == 4,
                  let completed = Int(components[2]),
                  let total = Int(components[3])
            else { return nil }
            self = .generating(completed: completed, total: total)
        case "decoding":
            self = .decoding
        case "writing":
            self = .writing
        default:
            return nil
        }
    }
}




extension ToolCall {

    var signature: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let arguments = (try? encoder.encode(function.arguments))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? String(describing: function.arguments)
        return "\(function.name)|\(arguments)"
    }
    
    
    var requiresUserApproval: Bool {
        switch function.name {
        case ToolNames.applyPatch,
             ToolNames.appClick,
             ToolNames.appDrag,
             ToolNames.appType,
             ToolNames.appKey,
             ToolNames.appMenu,
             ToolNames.createNote,
             ToolNames.updateNote,
             ToolNames.createCalendarEvent,
             ToolNames.updateCalendarEvent,
             ToolNames.createReminder,
             ToolNames.updateReminder,
             ToolNames.createMailDraft,
             ToolNames.runAppleScript,
             ToolNames.createSchedule,
             ToolNames.updateSchedule,
             ToolNames.deleteSchedule,
             ToolNames.setWorkday:
            true
        case ToolNames.executeCommand:
            !isReadOnlyCommand
        default:
            Connector(toolName: function.name) != nil
                && !ConnectorTool.isReadOnly(toolName: function.name)
        }
    }

    private var isReadOnlyCommand: Bool {
        guard let command = function.arguments["command"]?.stringValue else {
            return false
        }
        return ReadOnlyCommandPolicy.allows(command)
    }

    var approvalRequest: ToolApprovalRequest {
        ToolApprovalRequest(
            toolName: function.name,
            title: localizedDescription(.running),
            detail: approvalDetail)
    }

    private var approvalDetail: String? {
        switch function.name {
        case ToolNames.applyPatch:
            return patchFileChanges.map(\.path).formatted()
        case ToolNames.executeCommand:
            return function.arguments["command"]?.stringValue
        case ToolNames.textToImage, ToolNames.textToVideo, ToolNames.textToAudio:
            return function.arguments["prompt"]?.stringValue
        case ToolNames.appClick, ToolNames.appDrag, ToolNames.appType, ToolNames.appKey, ToolNames.appMenu:
            return function.arguments["app"]?.stringValue ?? String(localized: "Any window on screen")
        case ToolNames.createNote:
            return function.arguments["title"]?.stringValue
        case ToolNames.updateNote:
            return function.arguments["note_id"]?.stringValue
        case ToolNames.createCalendarEvent:
            let title = function.arguments["title"]?.stringValue ?? ""
            let start = function.arguments["start_at"]?.stringValue ?? ""
            let end = function.arguments["end_at"]?.stringValue ?? ""
            return String(localized: "\(title)\n\(start) – \(end)")
        case ToolNames.createReminder:
            return function.arguments["title"]?.stringValue
        case ToolNames.updateCalendarEvent:
            return function.arguments["event_id"]?.stringValue
        case ToolNames.updateReminder:
            return function.arguments["reminder_id"]?.stringValue
        case ToolNames.createMailDraft:
            let recipients = function.arguments["to"]?.arrayValue?
                .compactMap(\.stringValue)
                .joined(separator: ", ") ?? ""
            let subject = function.arguments["subject"]?.stringValue ?? ""
            return String(localized: "To: \(recipients)\nSubject: \(subject)")
        case ToolNames.runAppleScript:
            return function.arguments["script"]?.stringValue
        case ToolNames.createSchedule:
            let name = function.arguments["name"]?.stringValue ?? ""
            let prompt = function.arguments["prompt"]?.stringValue ?? ""
            return "\(name)\n\(prompt)"
        case ToolNames.updateSchedule, ToolNames.deleteSchedule:
            return function.arguments["schedule_id"]?.stringValue
        case ToolNames.setWorkday:
            let date = function.arguments["date"]?.stringValue ?? ""
            let kind = function.arguments["kind"]?.stringValue ?? ""
            return "\(date): \(kind)"
        default:
            guard Connector(toolName: function.name) != nil else { return nil }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(function.arguments))
                .map { String(decoding: $0, as: UTF8.self) }
        }
    }

    var fileDisplayName: String? {
        guard let path = function.arguments["path"]?.stringValue else {
            return nil
        }
        return (path as NSString).lastPathComponent
    }

    var patchFileChanges: [PatchFileChange] {
        guard function.name == ToolNames.applyPatch,
              let patch = function.arguments["patch"]?.stringValue
        else {
            return []
        }

        let directives: [(prefix: String, action: PatchFileAction)] = [
            ("*** Add File: ", .edit),
            ("*** Update File: ", .edit),
            ("*** Delete File: ", .delete)
        ]
        var changes: [PatchFileChange] = []

        for line in patch.components(separatedBy: "\n") {
            guard let directive = directives.first(where: { line.hasPrefix($0.prefix) }) else {
                continue
            }
            let path = String(line.dropFirst(directive.prefix.count))
            guard !path.isEmpty else { continue }

            let change = PatchFileChange(path: path, action: directive.action)
            if let index = changes.firstIndex(where: { $0.path == path }) {
                changes[index] = change
            } else {
                changes.append(change)
            }
        }

        return changes
    }

    func compactDescription(_ status: ToolCallStatus) -> String {
        guard function.name == ToolNames.executeCommand else {
            return localizedDescription(status)
        }

        switch status {
        case .running:
            return String(localized: "Running a command")
        case .completed:
            return String(localized: "Ran a command")
        case .failed:
            return String(localized: "Command failed")
        }
    }
    
    func localizedDescription(_ status: ToolCallStatus) -> String {
        let arguments = function.arguments
        switch function.name {
        case ToolNames.requestUserInput:
            switch status {
            case .running:
                return String(localized: "Waiting for user input")
            case .completed:
                return String(localized: "User input received")
            case .failed:
                return String(localized: "User input cancelled")
            }
        case ToolNames.readFile:
            let fileName = fileDisplayName ?? String(localized: "Unknown")
            switch status {
            case .running:
                return String(localized: "Reading \(fileName)")
            case .completed:
                return String(localized: "Read \(fileName)")
            case .failed:
                return String(localized: "Failed to read \(fileName)")
            }
        case ToolNames.applyPatch:
            let change = patchFileChanges.first
            let fileName = change?.fileName ?? String(localized: "Unknown")
            switch (change?.action ?? .edit, status) {
            case (.edit, .running):
                return String(localized: "Editing \(fileName)")
            case (.edit, .completed):
                return String(localized: "Edited \(fileName)")
            case (.edit, .failed):
                return String(localized: "Failed to edit \(fileName)")
            case (.delete, .running):
                return String(localized: "Deleting \(fileName)")
            case (.delete, .completed):
                return String(localized: "Deleted \(fileName)")
            case (.delete, .failed):
                return String(localized: "Failed to delete \(fileName)")
            }
        case ToolNames.listDirectory:
            switch status {
            case .running:
                return String(localized: "Listing directory")
            case .completed:
                return String(localized: "Listed directory")
            case .failed:
                return String(localized: "Failed to list directory")
            }
        case ToolNames.executeCommand:
            return compactDescription(status)
        case ToolNames.searchMap:
            let query = arguments["query"]?.stringValue ?? ""
            switch status {
            case .running:
                return String(localized: "Searching map for \(query)")
            case .completed:
                return String(localized: "Searched map for \(query)")
            case .failed:
                return String(localized: "Map search failed")
            }
        case ToolNames.searchProject, ToolNames.searchRelevantDocuments:
            let query = arguments["query"]?.stringValue ?? ""
            switch status {
            case .running:
                return String(localized: "Searching project for \(query)")
            case .completed:
                return String(localized: "Searched project for \(query)")
            case .failed:
                return String(localized: "Project search failed")
            }
        case ToolNames.webFetch:
            switch status {
            case .running:
                return String(localized: "Fetching web page")
            case .completed:
                return String(localized: "Fetched web page")
            case .failed:
                return String(localized: "Web fetch failed")
            }
        case ToolNames.appScreenshot:
            let app = arguments["app"]?.stringValue ?? String(localized: "the screen")
            return nativeDescription(status, running: "Taking a screenshot of \(app)", completed: "Took a screenshot of \(app)", failed: "Screenshot of \(app) failed")
        case ToolNames.appZoom:
            let app = arguments["app"]?.stringValue ?? String(localized: "the screen")
            return nativeDescription(status, running: "Zooming into \(app)", completed: "Zoomed into \(app)", failed: "Zooming into \(app) failed")
        case ToolNames.textToImage:
            switch status {
            case .running:
                return String(localized: "Creating image")
            case .completed: 
                return String(localized: "Image created")
            case .failed: 
                return String(localized: "Image creation failed")
            }
        case ToolNames.textToVideo:
            switch status {
            case .running: 
                return String(localized: "Creating video")
            case .completed:
                return String(localized: "Video created")
            case .failed:
                return String(localized: "Video creation failed")
            }
        case ToolNames.textToAudio:
            switch status {
            case .running:
                return String(localized: "Creating audio")
            case .completed:
                return String(localized: "Audio created")
            case .failed:
                return String(localized: "Audio creation failed")
            }
        case ToolNames.activateSkill:
            let name = arguments["name"]?.stringValue ?? ""
            switch status {
            case .running:
                return String(localized: "Loading skill \(name)")
            case .completed:
                return String(localized: "Loaded skill \(name)")
            case .failed:
                return String(localized: "Skill loading failed")
            }
        case ToolNames.searchTools:
            let query = arguments["query"]?.stringValue ?? ""
            switch status {
            case .running:
                return String(localized: "Searching tools for \(query)")
            case .completed:
                return String(localized: "Searched tools for \(query)")
            case .failed:
                return String(localized: "Tool search failed")
            }
        case ToolNames.listApps:
            return nativeDescription(status, running: "Listing running applications", completed: "Listed running applications", failed: "Failed to list running applications")
        case ToolNames.openApp:
            let app = arguments["app"]?.stringValue ?? ""
            return nativeDescription(status, running: "Opening \(app)", completed: "Opened \(app)", failed: "Opening \(app) failed")
        case ToolNames.appFind:
            let app = arguments["app"]?.stringValue ?? ""
            return nativeDescription(status, running: "Finding elements in \(app)", completed: "Found elements in \(app)", failed: "Finding elements in \(app) failed")
        case ToolNames.appClick:
            let app = arguments["app"]?.stringValue ?? String(localized: "the screen")
            return nativeDescription(status, running: "Clicking in \(app)", completed: "Clicked in \(app)", failed: "Click in \(app) failed")
        case ToolNames.appType:
            let app = arguments["app"]?.stringValue ?? ""
            return nativeDescription(status, running: "Typing in \(app)", completed: "Typed in \(app)", failed: "Typing in \(app) failed")
        case ToolNames.appKey:
            let keys = arguments["keys"]?.stringValue ?? ""
            return nativeDescription(status, running: "Pressing \(keys)", completed: "Pressed \(keys)", failed: "Pressing \(keys) failed")
        case ToolNames.appScroll:
            let app = arguments["app"]?.stringValue ?? String(localized: "the screen")
            return nativeDescription(status, running: "Scrolling in \(app)", completed: "Scrolled in \(app)", failed: "Scrolling in \(app) failed")
        case ToolNames.appDrag:
            let app = arguments["app"]?.stringValue ?? String(localized: "the screen")
            return nativeDescription(status, running: "Dragging in \(app)", completed: "Dragged in \(app)", failed: "Dragging in \(app) failed")
        case ToolNames.appMenu:
            let path = arguments["path"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " > ") ?? ""
            return nativeDescription(status, running: "Choosing \(path)", completed: "Chose \(path)", failed: "Choosing \(path) failed")
        case ToolNames.searchNotes, ToolNames.readNote:
            return nativeDescription(status, running: "Reading Notes", completed: "Read Notes", failed: "Notes operation failed")
        case ToolNames.createNote, ToolNames.updateNote:
            return nativeDescription(status, running: "Updating Notes", completed: "Updated Notes", failed: "Notes update failed")
        case ToolNames.searchCalendar, ToolNames.readCalendarEvent:
            return nativeDescription(status, running: "Reading Calendar", completed: "Read Calendar", failed: "Calendar operation failed")
        case ToolNames.createCalendarEvent, ToolNames.updateCalendarEvent:
            return nativeDescription(status, running: "Updating Calendar", completed: "Updated Calendar", failed: "Calendar update failed")
        case ToolNames.searchReminders, ToolNames.readReminder:
            return nativeDescription(status, running: "Reading Reminders", completed: "Read Reminders", failed: "Reminders operation failed")
        case ToolNames.createReminder, ToolNames.updateReminder:
            return nativeDescription(status, running: "Updating Reminders", completed: "Updated Reminders", failed: "Reminders update failed")
        case ToolNames.searchMail, ToolNames.readMail:
            return nativeDescription(status, running: "Reading Mail", completed: "Read Mail", failed: "Mail operation failed")
        case ToolNames.createMailDraft:
            return nativeDescription(status, running: "Creating Mail draft", completed: "Created Mail draft", failed: "Mail draft creation failed")
        case ToolNames.runAppleScript:
            return nativeDescription(status, running: "Running AppleScript", completed: "Ran AppleScript", failed: "AppleScript failed")
        case ToolNames.createSchedule:
            return nativeDescription(status, running: "Scheduling a task", completed: "Scheduled a task", failed: "Scheduling failed")
        case ToolNames.listSchedules:
            return nativeDescription(status, running: "Reading scheduled tasks", completed: "Read scheduled tasks", failed: "Reading scheduled tasks failed")
        case ToolNames.updateSchedule:
            return nativeDescription(status, running: "Updating a scheduled task", completed: "Updated a scheduled task", failed: "Scheduled task update failed")
        case ToolNames.deleteSchedule:
            return nativeDescription(status, running: "Deleting a scheduled task", completed: "Deleted a scheduled task", failed: "Scheduled task deletion failed")
        case ToolNames.listWorkdays:
            return nativeDescription(status, running: "Checking workdays", completed: "Checked workdays", failed: "Workday check failed")
        case ToolNames.setWorkday:
            return nativeDescription(status, running: "Updating workdays", completed: "Updated workdays", failed: "Workday update failed")
        case ToolNames.readSettings:
            return nativeDescription(status, running: "Reading settings", completed: "Read settings", failed: "Reading settings failed")
        case ToolNames.updateSettings:
            return nativeDescription(status, running: "Changing settings", completed: "Changed settings", failed: "Settings change failed")
        case ToolNames.openPage:
            return nativeDescription(status, running: "Opening a page", completed: "Opened a page", failed: "Opening the page failed")
        case ToolNames.listProjects:
            return nativeDescription(status, running: "Reading projects", completed: "Read projects", failed: "Reading projects failed")
        case ToolNames.createProject:
            return nativeDescription(status, running: "Creating a project", completed: "Created a project", failed: "Project creation failed")
        case ToolNames.updateProject:
            return nativeDescription(status, running: "Renaming a project", completed: "Renamed a project", failed: "Project rename failed")
        default:
            guard let connector = Connector(toolName: function.name) else {
                return String(localized: "Unknown Tool Call")
            }
            switch status {
            case .running:
                return String(localized: "Using \(connector.name)")
            case .completed:
                return String(localized: "Used \(connector.name)")
            case .failed:
                return String(localized: "\(connector.name) failed")
            }
        }
    }

    private func nativeDescription(
        _ status: ToolCallStatus,
        running: LocalizedStringResource,
        completed: LocalizedStringResource,
        failed: LocalizedStringResource
    ) -> String {
        switch status {
        case .running: String(localized: running)
        case .completed: String(localized: completed)
        case .failed: String(localized: failed)
        }
    }
    
    var icon: String {
        switch function.name {
        case ToolNames.requestUserInput: "questionmark.bubble"
        case ToolNames.readFile: "doc.text.magnifyingglass"
        case ToolNames.applyPatch: "square.and.pencil"
        case ToolNames.listDirectory: "folder"
        case ToolNames.executeCommand : "apple.terminal"
        case ToolNames.searchMap: "map"
        case ToolNames.searchProject, ToolNames.searchRelevantDocuments: "magnifyingglass"
        case ToolNames.webFetch: "network"
        case ToolNames.textToImage: "photo"
        case ToolNames.textToVideo: "video"
        case ToolNames.textToAudio: "waveform"
        case ToolNames.activateSkill: "sparkles"
        case ToolNames.searchTools: "wrench.and.screwdriver"
        case ToolNames.listApps: "app.badge"
        case ToolNames.openApp: "arrow.up.forward.app"
        case ToolNames.appFind: "list.bullet.indent"
        case ToolNames.appClick: "cursorarrow.click"
        case ToolNames.appDrag: "hand.draw"
        case ToolNames.appScroll: "arrow.up.and.down"
        case ToolNames.appScreenshot: "macwindow"
        case ToolNames.appZoom: "plus.magnifyingglass"
        case ToolNames.appType: "keyboard"
        case ToolNames.appKey: "command"
        case ToolNames.appMenu: "filemenu.and.selection"
        case ToolNames.searchNotes, ToolNames.readNote,
             ToolNames.createNote, ToolNames.updateNote: "note.text"
        case ToolNames.searchCalendar, ToolNames.readCalendarEvent,
             ToolNames.createCalendarEvent, ToolNames.updateCalendarEvent: "calendar"
        case ToolNames.searchReminders, ToolNames.readReminder,
             ToolNames.createReminder, ToolNames.updateReminder: "checklist"
        case ToolNames.searchMail, ToolNames.readMail,
             ToolNames.createMailDraft: "envelope"
        case ToolNames.runAppleScript: "applescript"
        case ToolNames.createSchedule, ToolNames.listSchedules,
             ToolNames.updateSchedule, ToolNames.deleteSchedule: "clock.arrow.circlepath"
        case ToolNames.listWorkdays, ToolNames.setWorkday: "calendar.badge.clock"
        case ToolNames.readSettings, ToolNames.updateSettings: "gearshape"
        case ToolNames.openPage: "sidebar.left"
        case ToolNames.listProjects, ToolNames.createProject, ToolNames.updateProject: "folder.badge.gearshape"
        default: "exclamationmark.triangle"
        }
    }
}

extension ToolCall {
    /// The kinds of work this call does, each with what makes it one occurrence:
    /// a file for file work, an app for app use, and the call itself otherwise.
    func activities(id: String) -> [(ToolCallActivity, String)] {
        let name = function.name
        switch name {
        case ToolNames.applyPatch:
            return patchFileChanges.map { change in
                (change.action == .delete ? .deleteFile : .editFile, change.path)
            }
        case ToolNames.readFile:
            return [(.readFile, function.arguments["path"]?.stringValue ?? id)]
        case ToolNames.listDirectory:
            return [(.listDirectory, function.arguments["path"]?.stringValue ?? id)]
        case ToolNames.executeCommand:
            return [(.runCommand, id)]
        case ToolNames.runAppleScript:
            return [(.runScript, id)]
        case ToolNames.searchMap, ToolNames.searchProject,
             ToolNames.searchRelevantDocuments, ToolNames.searchTools:
            return [(.search, id)]
        case ToolNames.webFetch:
            return [(.fetchWebPage, id)]
        case ToolNames.appScreenshot, ToolNames.appZoom:
            return [(.takeScreenshot, id)]
        case ToolNames.listApps, ToolNames.openApp, ToolNames.appFind, ToolNames.appClick,
             ToolNames.appType, ToolNames.appKey, ToolNames.appScroll, ToolNames.appDrag,
             ToolNames.appMenu:
            return [(.controlComputer, id)]
        case ToolNames.textToImage:
            return [(.createImage, id)]
        case ToolNames.textToVideo:
            return [(.createVideo, id)]
        case ToolNames.textToAudio:
            return [(.createAudio, id)]
        case ToolNames.activateSkill:
            return [(.loadSkill, id)]
        case ToolNames.requestUserInput:
            return [(.askQuestion, id)]
        case ToolNames.searchNotes, ToolNames.readNote, ToolNames.createNote, ToolNames.updateNote:
            return [(.useApp, "Notes")]
        case ToolNames.searchCalendar, ToolNames.readCalendarEvent,
             ToolNames.createCalendarEvent, ToolNames.updateCalendarEvent:
            return [(.useApp, "Calendar")]
        case ToolNames.searchReminders, ToolNames.readReminder,
             ToolNames.createReminder, ToolNames.updateReminder:
            return [(.useApp, "Reminders")]
        case ToolNames.searchMail, ToolNames.readMail, ToolNames.createMailDraft:
            return [(.useApp, "Mail")]
        case ToolNames.listSchedules, ToolNames.listWorkdays:
            return [(.checkSchedule, id)]
        case ToolNames.createSchedule, ToolNames.updateSchedule,
             ToolNames.deleteSchedule, ToolNames.setWorkday:
            return [(.changeSchedule, function.arguments["schedule_id"]?.stringValue ?? id)]
        case ToolNames.readSettings, ToolNames.listProjects:
            return [(.checkModelCraft, id)]
        case ToolNames.updateSettings, ToolNames.openPage,
             ToolNames.createProject, ToolNames.updateProject:
            return [(.changeModelCraft, id)]
        default:
            guard let connector = Connector(toolName: name) else { return [] }
            return [(.useApp, connector.rawValue)]
        }
    }
}

enum ReadOnlyCommandPolicy {

    private static let simpleCommands: Set<String> = [
        "cat", "df", "du", "file", "grep", "head", "id", "ls", "mdls",
        "pgrep", "ps", "pwd", "stat", "sw_vers", "tail", "uname", "wc",
        "which"
    ]

    private static let readOnlyGitSubcommands: Set<String> = [
        "diff", "grep", "log", "ls-files", "rev-parse", "show", "status"
    ]

    static func allows(_ command: String) -> Bool {
        let forbiddenCharacters = CharacterSet(charactersIn: "\n\r;|&><`")
        guard command.rangeOfCharacter(from: forbiddenCharacters) == nil,
              !command.contains("$("),
              !command.contains("${")
        else {
            return false
        }

        let arguments = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let executable = arguments.first.map({ ($0 as NSString).lastPathComponent }) else {
            return false
        }

        if simpleCommands.contains(executable) {
            return true
        }

        switch executable {
        case "rg":
            return arguments.dropFirst().allSatisfy { !$0.hasPrefix("--pre") }
        case "find":
            let mutatingPrimaries: Set<String> = [
                "-delete", "-exec", "-execdir", "-fls", "-fprint", "-fprint0",
                "-ok", "-okdir"
            ]
            return arguments.dropFirst().allSatisfy { !mutatingPrimaries.contains($0) }
        case "git":
            guard arguments.count >= 2 else {
                return false
            }
            if arguments[1] == "branch" {
                let options = Array(arguments.dropFirst(2))
                return options.isEmpty
                    || options == ["--show-current"]
                    || options == ["--list"]
            }
            guard readOnlyGitSubcommands.contains(arguments[1]) else { return false }
            return arguments.dropFirst(2).allSatisfy {
                !$0.hasPrefix("--output") && $0 != "--ext-diff"
            }
        default:
            return false
        }
    }
}
