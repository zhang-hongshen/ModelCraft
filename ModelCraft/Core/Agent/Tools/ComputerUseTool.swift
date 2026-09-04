//
//  ComputerUseTool.swift
//  ModelCraft
//
//  Created by Hongshen on 12/6/26.
//

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
        description: "List visible running applications and their bundle identifiers. Use this when the target application's bundle identifier is unknown; pass the returned appID to application UI inspection and interaction tools.",
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
            Inspect the accessible UI hierarchy of all visible windows for an application.
            Use this before click_element or type_text, and call it again after an action to verify the resulting state. Use capture_app_window when visual layout is needed or the accessibility tree is incomplete.
            ### Output Format Specification:
            The return value is a list of strings representing the UI tree. Elements follow these formats:
            1. **Interactive Elements**: Used for elements you can interact with.
               - Format: '[index][:]<type attributes path=hierarchy>[interactive]'
               - Example: '1[:]<AXButton enabled=true title=Save actions=AXPress path=/AXWindow/AXButton(title=Save)>[interactive]'
            2. **Context Elements**: Used for non-interactive text or containers.
               - Format: '_[:]<type>[context]'
               - Example: '_[:]<AXStaticText value=20>[context]'
            
            ### How to Use the Output:
            - When performing actions like clicking or typing, reference the numeric `[index]` of the Interactive Elements.
            - Use Context Elements to understand the screen's state, labels, or layout.
        """,
        parameters: [
            .required("appID", type: .string, description: "The target application's bundle identifier, normally obtained from list_running_application, for example `com.apple.Safari`."),
            .optional("appName", type: .string, description: "The target application's localized visible name, used as a fallback when appID does not match, for example `Safari`."),
            .optional("maxDepth", type: .int, description: "Maximum accessibility-tree depth to traverse. Omit it to use 30; lower values return less nested context.")
        ]
    ) { input in
        if !checkAccessibilityPermission() {
            throw ComputerUseToolError.accessibilityPermissionNotGranted
        }

        let app = try await findAndActivateApp(appID: input.appID, appName: input.appName)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        
        let maxDepth = input.maxDepth ?? 30
        let tree = UIManager.shared.getUITree(
            appID: app.bundleIdentifier ?? input.appID,
            element: appElement,
            depth: 0,
            maxDepth: maxDepth
        )
        return tree.isEmpty ? ["No accessible UI elements were found for this application."] : tree
    }

    // MARK: - Click an element
    static let clickElement = Tool<ClickElementInput, ActionOutput>(
        name: "click_element",
        description: "Perform one advertised accessibility action on a semantic UI element. Call get_ui_hierarchy first and use its current index and action name; indexes become stale after UI changes. Call get_ui_hierarchy again after the action, or capture_app_window for visual state, before treating the interaction as successful.",
        parameters: [
            .required("appID", type: .string, description: "The bundle identifier used in the get_ui_hierarchy call that produced the element index."),
            .optional("appName", type: .string, description: "The localized application name used as a fallback when appID does not match a running app."),
            .required("index", type: .int, description: "A current numeric interactive-element index returned by get_ui_hierarchy for this application."),
            .required("action", type: .string, description: "One exact accessibility action advertised on that indexed element, for example `AXPress`.")
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

        guard input.action == kAXPressAction else {
            return ActionOutput(
                success: false,
                error: ComputerUseToolError.actionFailed(
                    "The element did not perform \(input.action). Refresh the UI hierarchy before retrying."
                ).errorDescription
            )
        }

        // AXPress can fall back to a click at the element's center.
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
        description: "Replace the full value of a semantic editable text field or text area. Call get_ui_hierarchy first and use a current editable element index; indexes become stale after UI changes. Inspect the hierarchy again after typing, or capture_app_window for visual state, before treating the interaction as successful.",
        parameters: [
            .required("appID", type: .string, description: "The bundle identifier used in the get_ui_hierarchy call that produced the element index."),
            .optional("appName", type: .string, description: "The localized application name used as a fallback when appID does not match a running app."),
            .required("index", type: .int, description: "A current index for an editable element returned by get_ui_hierarchy for this application."),
            .required("text", type: .string, description: "The complete value to place in the element, replacing its existing text rather than appending to it.")
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
        description: "Send one virtual keyboard key press or key combination to a target application, such as Return, Tab, Command+A, or Escape. Inspect the hierarchy or capture the application again afterward before treating any resulting UI change as successful.",
        parameters: [
            .required("appID", type: .string, description: "The target application's bundle identifier, normally obtained from list_running_application."),
            .optional("appName", type: .string, description: "The localized application name used as a fallback when appID does not match a running app."),
            .required("keyCode", type: .int, description: "The macOS virtual key code, for example 36 for Return, 48 for Tab, or 53 for Escape."),
            .optional("modifiers", type: .array(elementType: .string), description: "Modifier names held during the key press. Supported values are `command`, `shift`, `option`, and `control`; omit for no modifiers.")
        ]
    ) { input in
        if !checkAccessibilityPermission() {
            throw ComputerUseToolError.accessibilityPermissionNotGranted
        }

        let app = try await findAndActivateApp(appID: input.appID, appName: input.appName)

        let flags = modifierFlags(for: input.modifiers ?? [])
        ScreenControlManager.shared.pressKey(
            keyCode: CGKeyCode(input.keyCode),
            modifiers: flags
        )
        return ActionOutput(success: true, error: nil)
    }

    static func modifierFlags(for names: [String]) -> [CGEventFlags] {
        names.compactMap { name in
            switch name.lowercased() {
            case "command", "cmd": .maskCommand
            case "shift": .maskShift
            case "option", "alt": .maskAlternate
            case "control", "ctrl": .maskControl
            default: nil
            }
        }
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
