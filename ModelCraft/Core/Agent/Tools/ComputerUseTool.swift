//
//  ComputerUseTool.swift
//  ModelCraft
//
//  Created by Hongshen on 12/6/26.
//

import UniformTypeIdentifiers
import MLXLMCommon
import ApplicationServices
import AppKit
import CoreGraphics


class ComputerUseTool {

    static let allTools: [any ToolProtocol] = [
        listRunningApplication,
        getUIHierarchy,
        clickElement,
        typeText,
        pressKey
    ]

    // MARK: - List Running Apps

    static let listRunningApplication = Tool<ListRunningApplicationInput, [RunningAppInfo]>(
        name: "list_running_application",
        description: "List all running applications",
        parameters: []
    ) { _ in
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .map { app in
                RunningAppInfo(
                    name: app.localizedName ?? "Unknown",
                    appID: app.bundleIdentifier
                )
            }
    }

    // MARK: - AX Tree Capture

    static let getUIHierarchy = Tool<GetUIHierarchyInput, [String]>(
        name: "get_ui_hierarchy",
        description: """
            Get the complete structure layout and UI element hierarchy of all windows for a given application.
            Use this tool whenever you need to inspect the current state of an application, look for elements to interact with, or verify if an action (click/type) was successful.
            ### Output Format Specification:
            The return value is a list of strings representing the UI tree. Elements follow these formats:
            1. **Interactive Elements**: Used for elements you can interact with.
               - Format: '[index][:]<type>[interactive]'
               - Example: '1[:]<AXButton enabled=true actions=AXPress>[interactive]'
            2. **Context Elements**: Used for non-interactive text or containers.
               - Format: '_[:]<type>[context]'
               - Example: '_[:]<AXStaticText value=20>[context]'
            
            ### How to Use the Output:
            - When performing actions like clicking or typing, reference the numeric `[index]` of the Interactive Elements.
            - Use Context Elements to understand the screen's state, labels, or layout.
        """,
        parameters: [
            .required("appID", type: .string, description: "Bundle identifier of the target app, e.g. 'com.apple.Safari'"),
            .optional("appName", type: .string, description: "Localized name of the target app, e.g. 'Safari'"),
            .optional("maxDepth", type: .int, description: "Maximum UI hierarchy tree depth to traverse (default 30)")
        ]
    ) { input in
        if !checkAccessibilityPermission() {
            throw ComputerUseToolError.accessibilityPermissionNotGranted
        }

        let app = try await findAndActivateApp(appID: input.appID, appName: input.appName)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        
        let maxDepth = input.maxDepth ?? 30
        return UIManager.shared.getUITree(appID: app.bundleIdentifier ?? "", element: appElement, depth: 0, maxDepth: maxDepth)
    }

    // MARK: - Click an element
    static let clickElement = Tool<ClickElementInput, ActionOutput>(
        name: "click_element",
        description: "Click element and choose action",
        parameters: [
            .required("appID", type: .string, description: "Bundle identifier of the target app, e.g. 'com.apple.Safari'"),
            .optional("appName", type: .string, description: "Localized name of the target app, e.g. 'Safari'"),
            .required("index", type: .int, description: "index of the element"),
            .required("action", type: .string, description: "action to perform, e.g. AXPress")
        ]
    ) { input in
        if !checkAccessibilityPermission() {
            throw ComputerUseToolError.accessibilityPermissionNotGranted
        }
        let app = try await findAndActivateApp(appID: input.appID, appName: input.appName)
        guard let element = UIManager.shared.searchElement(appID: app.bundleIdentifier ?? "", index: input.index) else {
            throw ComputerUseToolError.uiElementNotFound
        }
        
        if element.performAction(input.action) {
            return ActionOutput(success: true, error: nil)
        }
        
        // Fall back to synthetic click at element's center if unsupported
        guard let frame = element.frame else {
            throw ComputerUseToolError.uiElementNotFound
        }

        // Bring the target app forward so the click lands on it
        app.activate(options: [])
        let center = CGPoint(x: frame.midX, y: frame.midY)
        ScreenControlManager.shared.click(at: center)
        
        return ActionOutput(success: true, error: nil)
    }

    // MARK: - Type Text
    static let typeText = Tool<TypeTextInput, ActionOutput>(
        name: "type_text",
        description: "Find a text field in a target app and set its value",
        parameters: [
            .required("appIdentifier", type: .string, description: "Bundle identifier of the target app, e.g. 'com.apple.Safari'"),
            .optional("appName", type: .string, description: "Localized name of the target app, e.g. 'Safari'"),
            .required("index", type: .int, description: "index of the element")
        ]
    ) { input in
        if !checkAccessibilityPermission() {
            throw ComputerUseToolError.accessibilityPermissionNotGranted
        }

        let app = try await findAndActivateApp(appID: input.appID, appName: input.appName)

        guard let element = UIManager.shared.searchElement(appID: app.bundleIdentifier ?? "", index: input.index) else {
            return ActionOutput(success: false, error: ComputerUseToolError.uiElementNotFound.errorDescription)
        }

        // Focus the element first
        element.setAttribute(kAXFocusedAttribute, value: kCFBooleanTrue)


        // Try setting AXValue directly
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)

        if settable.boolValue && element.setAttribute(kAXValueAttribute, value: input.text as CFTypeRef) == .success {
            return ActionOutput(success: true, error: nil)
        }

        // Fallback: bring app forward, click into field, then simulate typing
        app.activate(options: [])
        guard let frame = element.frame else {
            return ActionOutput(success: false, error: "Can not get element frame")
        }
        
        ScreenControlManager.shared.click(x: frame.midX, y: frame.midY)
        ScreenControlManager.shared.typeString(input.text)
        
        return ActionOutput(success: true, error: nil)
    }

    // MARK: - Press a key / key combo
    static let pressKey = Tool<PressKeyInput, ActionOutput>(
        name: "press_key",
        description: "Send a keyboard key press or key combination (e.g. Return, Tab, Cmd+A, Escape) to a target app.",
        parameters: [
            .required("appID", type: .string, description: "Bundle identifier of the target app, e.g. 'com.apple.Safari'"),
            .optional("appName", type: .string, description: "Localized name of the target app, e.g. 'Safari'"),
            .required("keyCode", type: .int, description: "Virtual key code (e.g. 36 = Return, 48 = Tab, 53 = Escape)"),
            .optional("modifiers", type: .array(elementType: .string), description: "Modifier keys: 'command', 'shift', 'option', 'control'")
        ]
    ) { input in
        
        let app = try await findAndActivateApp(appID: input.appID, appName: input.appName)

        var flags: [CGEventFlags] = []
        for modifier in input.modifiers ?? [] {
            switch modifier.lowercased() {
            case "command", "cmd": flags.append(.maskCommand)
            case "shift": flags.append(.maskShift)
            case "option", "alt": flags.append(.maskAlternate)
            case "control", "ctrl" : flags.append(.maskCommand)
            default: break
            }
        }
        
        ScreenControlManager.shared.pressKey(keyCode: CGKeyCode(input.keyCode), modifiers: flags)
        return ActionOutput(success: true, error: nil)
    }

    
    private static func checkAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    func openAccessibilitySettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - App Finder
    /// find a target NSRunningApplication by bundle identifier or name, launching it if necessary.
    private static func findAndActivateApp(appID: String, appName: String?) async throws -> NSRunningApplication {
        
        if let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: appID).first {
            runningApp.activate()
            return runningApp
        }
        
        if let appName = appName, !appName.isEmpty {
            let runningApps = NSWorkspace.shared.runningApplications
            
            if let exactMatch = runningApps.first(where: { $0.localizedName?.localizedCaseInsensitiveCompare(appName) == .orderedSame }) {
                exactMatch.activate()
                return exactMatch
            }
            
            if let partialMatch = runningApps.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(appName) ?? false }) {
                partialMatch.activate()
                return partialMatch
            }
        }
        
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            
            let launchedApp = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            
            try await Task.sleep(nanoseconds: 500_000_000)
            
            return launchedApp
        }
        
        
        let identityInfo = appName != nil ? "\(appID) (\(appName!))" : appID
        throw ComputerUseToolError.appNotFound("Application \(identityInfo) is neither running nor install-detected.")
    }
    
}


enum ComputerUseToolError: Error, LocalizedError {
    case accessibilityPermissionNotGranted
    case uiElementNotFound
    case actionFailed(String)
    case appNotFound(String)

    var errorDescription: String {
        switch self {
        case .accessibilityPermissionNotGranted:
            return "Accessibility permission not granted. Enable in System Settings > Privacy & Security > Accessibility."
        case .uiElementNotFound:
            return "Could not find a matching UI element."
        case .actionFailed(let reason):
            return "Action failed: \(reason)"
        case .appNotFound(let reason):
            return reason
        }
    }
}

// MARK: - Types
struct RunningAppInfo: Codable {
    let name: String
    let appID: String?
}

// MARK: - Input/Output Types

struct ListRunningApplicationInput: Codable {}

struct GetUIHierarchyInput: Codable {
    let appID: String
    let appName: String?
    let maxDepth: Int?
}

struct ClickElementInput: Codable {
    let appID: String
    let appName: String?
    let index: Int
    let action: String
}

struct TypeTextInput: Codable {
    let appID: String
    let appName: String?
    let index: Int
    let text: String
}

struct PressKeyInput: Codable {
    let appID: String
    let appName: String?
    let keyCode: Int
    let modifiers: [String]?
}

struct ActionOutput: Codable {
    let success: Bool
    let error: String?
}
