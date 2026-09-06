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
    static let writeFile = "write_file"
    static let editFile = "edit_file"
    static let listDirectory = "list_directory"

    // MARK: Command Tool
    static let executeCommand = "execute_command"

    // MARK: Search Tool
    static let searchMap = "search_map"
    static let searchProject = "search_project"
    static let searchRelevantDocuments = "search_relevant_documents"
    static let webFetch = "web_fetch"

    // MARK: Screen Control Tool
    static let captureFullScreen = "capture_full_screen"
    static let captureAppWindow = "capture_app_window"
    static let move = "move"
    static let click = "click"
    static let drag = "drag"
    static let scroll = "scroll"

    // MARK: Skill Tool
    static let activateSkill = "activate_skill"

    // MARK: Image Tool
    static let textToImage = "text_to_image"

    // MARK: Video Tool
    static let textToVideo = "text_to_video"

    // MARK: Audio Tool
    static let textToAudio = "text_to_audio"

    // MARK: Computer Use Tool
    static let listRunningApps = "list_running_application"
    static let getUIHierarchy = "get_ui_hierarchy"
    static let clickElement = "click_element"
    static let typeText = "type_text"
    static let pressKey = "press_key"
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
        case ToolNames.writeFile,
             ToolNames.editFile,
             ToolNames.click,
             ToolNames.drag,
             ToolNames.clickElement,
             ToolNames.typeText,
             ToolNames.pressKey:
            true
        case ToolNames.executeCommand:
            !isReadOnlyCommand
        default:
            false
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
        case ToolNames.writeFile, ToolNames.editFile:
            function.arguments["path"]?.stringValue
        case ToolNames.executeCommand:
            function.arguments["command"]?.stringValue
        case ToolNames.textToImage, ToolNames.textToVideo, ToolNames.textToAudio:
            function.arguments["prompt"]?.stringValue
        case ToolNames.clickElement, ToolNames.typeText, ToolNames.pressKey:
            function.arguments["appID"]?.stringValue
        default:
            nil
        }
    }

    var fileDisplayName: String? {
        guard let path = function.arguments["path"]?.stringValue else {
            return nil
        }
        return (path as NSString).lastPathComponent
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
        case ToolNames.writeFile:
            let fileName = fileDisplayName ?? String(localized: "Unknown")
            switch status {
            case .running:
                return String(localized: "Writing into \(fileName)")
            case .completed:
                return String(localized: "Wrote into \(fileName)")
            case .failed:
                return String(localized: "Failed to write into \(fileName)")
            }
        case ToolNames.editFile:
            let fileName = fileDisplayName ?? String(localized: "Unknown")
            switch status {
            case .running:
                return String(localized: "Editing \(fileName)")
            case .completed:
                return String(localized: "Edited \(fileName)")
            case .failed:
                return String(localized: "Failed to edit \(fileName)")
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
        case ToolNames.click:
            let x = arguments["x"]?.doubleValue ?? 0
            let y = arguments["y"]?.doubleValue ?? 0
            switch status {
            case .running:
                return String(localized: "Clicking (\(x), \(y))")
            case .completed:
                return String(localized: "Clicked (\(x), \(y))")
            case .failed:
                return String(localized: "Click failed at (\(x), \(y))")
            }
        case ToolNames.move:
            let x = arguments["x"]?.doubleValue ?? 0
            let y = arguments["y"]?.doubleValue ?? 0
            switch status {
            case .running:
                return String(localized: "Moving pointer to (\(x), \(y))")
            case .completed:
                return String(localized: "Moved to (\(x), \(y))")
            case .failed:
                return String(localized: "Move failed")
            }
        case ToolNames.captureFullScreen:
            switch status {
            case .running:
                return String(localized: "Taking full screenshot")
            case .completed:
                return String(localized: "Full screenshot captured")
            case .failed:
                return String(localized: "Full screenshot failed")
            }
        case ToolNames.captureAppWindow:
            switch status {
            case .running:
                return String(localized: "Capturing application windows")
            case .completed:
                return String(localized: "Captured application windows")
            case .failed:
                return String(localized: "Application window capture failed")
            }
        case ToolNames.drag:
            switch status {
            case .running:
                return String(localized: "Dragging pointer")
            case .completed:
                return String(localized: "Dragged pointer")
            case .failed:
                return String(localized: "Drag failed")
            }
        case ToolNames.scroll:
            switch status {
            case .running:
                return String(localized: "Scrolling")
            case .completed:
                return String(localized: "Scrolled")
            case .failed:
                return String(localized: "Scroll failed")
            }
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
        case ToolNames.listRunningApps:
            switch status {
            case .running:
                return String(localized: "Listing running applications")
            case .completed:
                return String(localized: "Listed running applications")
            case .failed:
                return String(localized: "Failed to list running applications")
            }
        case ToolNames.getUIHierarchy:
            switch status {
            case .running:
                return String(localized: "Inspecting UI hierarchy")
            case .completed:
                return String(localized: "Inspected UI hierarchy")
            case .failed:
                return String(localized: "UI hierarchy inspection failed")
            }
        case ToolNames.clickElement:
            switch status {
            case .running:
                return String(localized: "Clicking an element")
            case .completed:
                return String(localized: "Clicked an element")
            case .failed:
                return String(localized: "Element click failed")
            }
        case ToolNames.typeText:
            switch status {
            case .running:
                return String(localized: "Typing text")
            case .completed:
                return String(localized: "Typed text")
            case .failed:
                return String(localized: "Text input failed")
            }
        case ToolNames.pressKey:
            switch status {
            case .running:
                return String(localized: "Pressing a key")
            case .completed:
                return String(localized: "Pressed a key")
            case .failed:
                return String(localized: "Key press failed")
            }
        default:
            return String(localized: "Unknown Tool Call")
        }
    }
    
    var icon: String {
        switch function.name {
        case ToolNames.requestUserInput: "questionmark.bubble"
        case ToolNames.readFile: "doc.text.magnifyingglass"
        case ToolNames.writeFile, ToolNames.editFile: "square.and.pencil"
        case ToolNames.listDirectory: "folder"
        case ToolNames.executeCommand : "apple.terminal"
        case ToolNames.searchMap: "map"
        case ToolNames.searchProject, ToolNames.searchRelevantDocuments: "magnifyingglass"
        case ToolNames.webFetch: "network"
        case ToolNames.textToImage: "photo"
        case ToolNames.textToVideo: "video"
        case ToolNames.textToAudio: "waveform"
        case ToolNames.activateSkill: "sparkles"
        case ToolNames.listRunningApps: "app.badge"
        case ToolNames.getUIHierarchy: "list.bullet.indent"
        case ToolNames.click, ToolNames.clickElement, ToolNames.move, ToolNames.drag: "pointer.arrow"
        case ToolNames.scroll: "arrow.up.and.down"
        case ToolNames.captureFullScreen: "display.2"
        case ToolNames.captureAppWindow: "macwindow"
        case ToolNames.typeText, ToolNames.pressKey: "keyboard"
        default: "exclamationmark.triangle"
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
