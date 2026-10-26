//
//  ComputerUseTool.swift
//  ModelCraft
//
//  Created by Hongshen on 12/6/26.
//

import MLXLMCommon
import ApplicationServices
import AppKit
import Carbon.HIToolbox
import CoreGraphics


enum ComputerUseTool {

    static let allTools: [any ToolProtocol] = [
        listApps,
        openApp,
        appFind,
        appClick,
        appType,
        appKey,
        appScroll,
        appDrag,
        appMenu
    ]

    static let appDescription = "The application: its name as list_apps shows it, such as `Safari`, or its bundle identifier, such as `com.apple.Safari`. A running application is brought to the front; an installed one that is not running is opened."

    static let optionalAppDescription = "The application whose latest app_screenshot the coordinates refer to; it is brought to the front first. Omit it only for coordinates from an app_screenshot of the full screen."

    // MARK: - List Apps

    static let listApps = Tool<ListAppsInput, [RunningAppInfo]>(
        name: ToolNames.listApps,
        description: "List the applications running now with their names and bundle identifiers, and which one is frontmost. Read-only. The `app` parameter of the app tools takes a name or bundle identifier from this list; an installed application that is not running can also be named directly.",
        parameters: []
    ) { _ in
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { app in
                RunningAppInfo(
                    name: app.localizedName ?? "Unknown",
                    bundleID: app.bundleIdentifier,
                    frontmost: app.isActive,
                    hidden: app.isHidden
                )
            }
    }

    // MARK: - Open App

    static let openApp = Tool<OpenAppInput, OpenAppOutput>(
        name: ToolNames.openApp,
        description: "Open an application, or bring it to the front when it is already running, without acting in it. Returns its name, bundle identifier, and the titles of its windows. To see or operate its contents, follow with app_screenshot or app_find.",
        parameters: [
            .required("app", type: .string, description: appDescription)
        ]
    ) { input in
        let app = try await resolveApp(input.app)
        let windows: [AXUIElement] = AXUIElementCreateApplication(app.processIdentifier)
            .getAttribute(kAXWindowsAttribute) ?? []
        return OpenAppOutput(
            name: app.localizedName ?? input.app,
            bundleID: app.bundleIdentifier,
            windows: windows.map { $0.title ?? "" }
        )
    }

    // MARK: - Find Elements

    static let appFind = Tool<AppFindInput, [String]>(
        name: ToolNames.appFind,
        description: """
            Find UI elements in an application's windows and menu bar through the macOS Accessibility API. Returns one line per element with its role, title, value, and advertised actions. Read-only.
            Interactive lines start with a numeric index, as in `3[:]<AXButton title=Save actions=AXPress path=...>[interactive]`; pass that index as `element` to app_click, app_type, or app_scroll. Lines starting with `_` carry text and context only. An index is valid until the next app_find of the same application, and any change in the interface can make it stale.
            Web page content in browsers and Electron applications often exposes few elements; use app_screenshot for those. For Notes, Reminders, Calendar, or Mail data, prefer their typed tools.
            """,
        parameters: [
            .required("app", type: .string, description: appDescription),
            .optional("query", type: .string, description: "Words that must all appear in an element's line, ignoring case, such as `save button` or a field's label. Omit it to return every element."),
            .optional("max_depth", type: .int, description: "How deep to walk the element tree. Defaults to 30; lower values return less nested content.")
        ]
    ) { input in
        try checkAccessibilityPermission()
        let app = try await resolveApp(input.app)
        try Task.checkCancellation()
        let lines = UIManager.shared.getUITree(
            appID: cacheKey(of: app),
            element: AXUIElementCreateApplication(app.processIdentifier),
            depth: 0,
            maxDepth: input.maxDepth ?? 30
        )
        guard !lines.isEmpty else {
            return ["No accessible UI elements were found for this application. Use app_screenshot to see it."]
        }
        let terms = input.query?.lowercased().split(whereSeparator: \.isWhitespace) ?? []
        guard !terms.isEmpty else { return lines }
        let matches = lines.filter { line in
            let lowered = line.lowercased()
            return terms.allSatisfy { lowered.contains($0) }
        }
        return matches.isEmpty
            ? ["No element matched `\(input.query ?? "")` among \(lines.count) elements. Try fewer or different words, or omit query."]
            : matches
    }

    // MARK: - Click

    static let appClick = Tool<AppClickInput, ActionOutput>(
        name: ToolNames.appClick,
        description: "Click in an application, either on an element from app_find or at a pixel of the latest app_screenshot of that application. With an element and a plain single left click, its accessibility press action is used, which works even when the element is covered; otherwise the click is posted at the element's center. The user's own pointer does not move. Use `button` for a context menu and `clicks` for a double or triple click. The click takes effect immediately; check the outcome with app_screenshot or app_find before reporting success.",
        parameters: [
            .optional("app", type: .string, description: "\(appDescription) Required with `element`. \(optionalAppDescription)"),
            .optional("element", type: .int, description: "An interactive element index from the latest app_find of this application."),
            .optional("x", type: .double, description: "Pixels from the left edge of the latest app_screenshot. Required with `y` when `element` is omitted."),
            .optional("y", type: .double, description: "Pixels from the top edge of the latest app_screenshot. Required with `x` when `element` is omitted."),
            .optional("button", type: .string, description: "The mouse button. Defaults to `left`; `right` opens a context menu.", extraProperties: ["enum": ["left", "right"]]),
            .optional("clicks", type: .int, description: "1 for a single click (the default), 2 for a double click, 3 for a triple click."),
            .optional("modifiers", type: .array(elementType: .string), description: "Keys held during the click: `cmd`, `shift`, `option`, `ctrl`. Omit for none."),
            .optional("action", type: .string, description: "With `element` only: an accessibility action advertised by the element in app_find, such as `AXShowMenu` or `AXIncrement`, performed instead of a click.")
        ]
    ) { input in
        try checkAccessibilityPermission()
        let app: NSRunningApplication? = if let name = input.app { try await resolveApp(name) } else { nil }
        let button: CGMouseButton = input.button == "right" ? .right : .left
        let clicks = min(max(input.clicks ?? 1, 1), 3)
        let modifiers = try modifierFlags(for: input.modifiers ?? []).reduce(CGEventFlags()) { $0.union($1) }

        let point: CGPoint
        if let index = input.element {
            guard let app else { throw ComputerUseToolError.elementNeedsApp }
            let element = try cachedElement(index, in: app)
            if let action = input.action {
                guard element.performAction(action) else {
                    throw ComputerUseToolError.actionFailed(
                        "Element \(index) did not perform \(action). Use an action listed for it by app_find.")
                }
                return ActionOutput(result: "Performed \(action) on element \(index).")
            }
            if button == .left, clicks == 1, modifiers.isEmpty, element.performAction(kAXPressAction) {
                return ActionOutput(result: "Pressed element \(index).")
            }
            guard let frame = element.frame else { throw ComputerUseToolError.elementHasNoFrame(index) }
            point = CGPoint(x: frame.midX, y: frame.midY)
        } else {
            point = try screenPoint(x: input.x, y: input.y, app: app)
        }
        await ScreenControlManager.shared.click(at: point, button: button, count: clicks, modifiers: modifiers)
        return ActionOutput(result: "Clicked at (\(Int(point.x)), \(Int(point.y))) in screen points.")
    }

    // MARK: - Type Text

    static let appType = Tool<AppTypeInput, ActionOutput>(
        name: ToolNames.appType,
        description: "Type text into an application as keyboard input, at its focused element or into an element from app_find, which is focused first. Line breaks are typed as Return. With `replace`, the field's current contents are replaced instead of typed into at the insertion point. Use app_key for shortcuts and special keys. Check the outcome with app_find or app_screenshot before reporting success.",
        parameters: [
            .required("app", type: .string, description: appDescription),
            .required("text", type: .string, description: "The text to type."),
            .optional("element", type: .int, description: "An editable element index from the latest app_find of this application. Omit it to type into whatever has keyboard focus."),
            .optional("replace", type: .bool, description: "`true` replaces the field's whole contents: the value is set directly when the element allows it, otherwise everything is selected with Command-A first. Defaults to `false`, which types at the insertion point.")
        ]
    ) { input in
        try checkAccessibilityPermission()
        let app = try await resolveApp(input.app)
        try Task.checkCancellation()
        let replace = input.replace ?? false

        if let index = input.element {
            let element = try cachedElement(index, in: app)
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
            if replace, settable.boolValue,
               element.setAttribute(kAXValueAttribute, value: input.text as CFString) == .success {
                return ActionOutput(result: "Set the value of element \(index).")
            }
            if element.setAttribute(kAXFocusedAttribute, value: kCFBooleanTrue) != .success {
                guard let frame = element.frame else { throw ComputerUseToolError.elementHasNoFrame(index) }
                await ScreenControlManager.shared.click(at: CGPoint(x: frame.midX, y: frame.midY))
            }
        }
        if replace {
            ScreenControlManager.shared.pressKey(keyCode: CGKeyCode(kVK_ANSI_A), modifiers: [.maskCommand])
        }
        ScreenControlManager.shared.typeString(input.text)
        return ActionOutput(result: "Typed \(input.text.count) characters.")
    }

    // MARK: - Press Keys

    static let appKey = Tool<AppKeyInput, ActionOutput>(
        name: ToolNames.appKey,
        description: "Press a key or keyboard shortcut in an application, such as `return`, `escape`, `tab`, `down`, `cmd+a`, `cmd+shift+t`, or `ctrl+tab`. The application is brought to the front and receives the keys as if typed. Use app_type for text. Check the outcome with app_screenshot or app_find before reporting success.",
        parameters: [
            .required("app", type: .string, description: appDescription),
            .required("keys", type: .string, description: "A key, optionally preceded by modifiers joined with `+`. Modifiers: `cmd`, `shift`, `option` (or `alt`), `ctrl`, `fn`. Keys: a letter, digit, or punctuation character, `return`, `enter`, `tab`, `space`, `delete` (backspace), `forward_delete`, `escape`, `up`, `down`, `left`, `right`, `home`, `end`, `page_up`, `page_down`, or `f1` to `f12`."),
            .optional("repeat", type: .int, description: "How many times to press it. Defaults to 1; at most 50.")
        ]
    ) { input in
        try checkAccessibilityPermission()
        let parts = input.keys.lowercased().split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let keyName = parts.last, let keyCode = keyCodes[keyName] else {
            throw ComputerUseToolError.unknownKey(input.keys)
        }
        let modifiers = try modifierFlags(for: parts.dropLast())
        _ = try await resolveApp(input.app)
        for _ in 0..<min(max(input.`repeat` ?? 1, 1), 50) {
            try Task.checkCancellation()
            ScreenControlManager.shared.pressKey(keyCode: CGKeyCode(keyCode), modifiers: modifiers)
        }
        return ActionOutput(result: "Pressed \(input.keys).")
    }

    // MARK: - Scroll

    static let appScroll = Tool<AppScrollInput, ActionOutput>(
        name: ToolNames.appScroll,
        description: "Scroll with the scroll wheel at an element from app_find, at a pixel of the latest app_screenshot, or, when neither is given, at the center of the application's focused window. The user's own pointer does not move. Check the outcome with app_screenshot or app_find.",
        parameters: [
            .optional("app", type: .string, description: "\(appDescription) Required with `element` or when no position is given. \(optionalAppDescription)"),
            .required("direction", type: .string, description: "Which way the view moves through the content.", extraProperties: ["enum": ["up", "down", "left", "right"]]),
            .optional("amount", type: .int, description: "How many scroll-wheel notches, each about 40 points. Defaults to 5."),
            .optional("element", type: .int, description: "An element index from the latest app_find of this application to scroll inside."),
            .optional("x", type: .double, description: "Pixels from the left edge of the latest app_screenshot."),
            .optional("y", type: .double, description: "Pixels from the top edge of the latest app_screenshot.")
        ]
    ) { input in
        try checkAccessibilityPermission()
        let app: NSRunningApplication? = if let name = input.app { try await resolveApp(name) } else { nil }

        let point: CGPoint
        if let index = input.element {
            guard let app else { throw ComputerUseToolError.elementNeedsApp }
            guard let frame = try cachedElement(index, in: app).frame else {
                throw ComputerUseToolError.elementHasNoFrame(index)
            }
            point = CGPoint(x: frame.midX, y: frame.midY)
        } else if input.x != nil || input.y != nil {
            point = try screenPoint(x: input.x, y: input.y, app: app)
        } else {
            guard let app else { throw ComputerUseToolError.missingPosition }
            let window: AXUIElement? = AXUIElementCreateApplication(app.processIdentifier)
                .getAttribute(kAXFocusedWindowAttribute)
            guard let frame = window?.frame else { throw ScreenControlError.noWindows }
            point = CGPoint(x: frame.midX, y: frame.midY)
        }

        let distance = Int32(max(input.amount ?? 5, 1) * 40)
        let (deltaX, deltaY): (Int32, Int32) = switch input.direction {
        case "up": (0, distance)
        case "down": (0, -distance)
        case "left": (distance, 0)
        case "right": (-distance, 0)
        default: throw ComputerUseToolError.invalidDirection(input.direction)
        }
        await ScreenControlManager.shared.scroll(at: point, deltaX: deltaX, deltaY: deltaY)
        return ActionOutput(result: "Scrolled \(input.direction) at (\(Int(point.x)), \(Int(point.y))) in screen points.")
    }

    // MARK: - Drag

    static let appDrag = Tool<AppDragInput, ActionOutput>(
        name: ToolNames.appDrag,
        description: "Press the left mouse button at one pixel of the latest app_screenshot and drag to another, to move, resize, select, or reorder. The user's own pointer does not move. Check the outcome with app_screenshot before reporting success.",
        parameters: [
            .optional("app", type: .string, description: optionalAppDescription),
            .required("from_x", type: .double, description: "Starting pixels from the left edge of the latest app_screenshot."),
            .required("from_y", type: .double, description: "Starting pixels from the top edge of the latest app_screenshot."),
            .required("to_x", type: .double, description: "Ending pixels from the left edge of the latest app_screenshot."),
            .required("to_y", type: .double, description: "Ending pixels from the top edge of the latest app_screenshot.")
        ]
    ) { input in
        try checkAccessibilityPermission()
        let app: NSRunningApplication? = if let name = input.app { try await resolveApp(name) } else { nil }
        let start = try screenPoint(x: input.fromX, y: input.fromY, app: app)
        let end = try screenPoint(x: input.toX, y: input.toY, app: app)
        await ScreenControlManager.shared.drag(from: start, to: end)
        return ActionOutput(result: "Dragged from (\(Int(start.x)), \(Int(start.y))) to (\(Int(end.x)), \(Int(end.y))) in screen points.")
    }

    // MARK: - Menu

    static let appMenu = Tool<AppMenuInput, ActionOutput>(
        name: ToolNames.appMenu,
        description: "Choose a command from an application's menu bar by its path of titles, such as [`File`, `Export…`] or [`View`, `Sort By`, `Name`]; a path of one title opens that menu. Titles match ignoring case, and `...` matches `…`. When a title is not found, the error lists the titles available at that level, so a failed call shows the menu's contents. Check the outcome with app_screenshot or app_find before reporting success.",
        parameters: [
            .required("app", type: .string, description: appDescription),
            .required("path", type: .array(elementType: .string), description: "Menu titles from the menu bar to the command, such as [`Edit`, `Find`, `Find…`].")
        ]
    ) { input in
        try checkAccessibilityPermission()
        let app = try await resolveApp(input.app)
        guard !input.path.isEmpty,
              let menuBar: AXUIElement = AXUIElementCreateApplication(app.processIdentifier)
                .getAttribute(kAXMenuBarAttribute)
        else { throw ComputerUseToolError.menuItemNotFound(input.path.first ?? "", available: []) }

        func normalized(_ title: String) -> String {
            title.replacingOccurrences(of: "...", with: "…")
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
        }

        var items = menuBar.children
        var item: AXUIElement?
        for title in input.path {
            guard let match = items.first(where: { normalized($0.title ?? "") == normalized(title) }) else {
                throw ComputerUseToolError.menuItemNotFound(
                    title, available: items.compactMap(\.title).filter { !$0.isEmpty })
            }
            item = match
            // A menu bar item or submenu item holds its menu as its only child.
            items = match.children.first?.children ?? []
        }
        guard let item, item.enabled != false else {
            throw ComputerUseToolError.actionFailed("\(input.path.joined(separator: " > ")) is disabled.")
        }
        guard item.performAction(kAXPressAction) else {
            throw ComputerUseToolError.actionFailed("\(input.path.joined(separator: " > ")) could not be chosen.")
        }
        return ActionOutput(result: "Chose \(input.path.joined(separator: " > ")).")
    }

    // MARK: - Helpers

    /// Virtual key codes for the key names app_key accepts.
    static let keyCodes: [String: Int] = {
        var codes: [String: Int] = [
            "return": kVK_Return, "enter": kVK_ANSI_KeypadEnter, "tab": kVK_Tab,
            "space": kVK_Space, "delete": kVK_Delete, "backspace": kVK_Delete,
            "forward_delete": kVK_ForwardDelete, "escape": kVK_Escape, "esc": kVK_Escape,
            "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "home": kVK_Home, "end": kVK_End, "page_up": kVK_PageUp, "page_down": kVK_PageDown,
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
            "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket,
            "]": kVK_ANSI_RightBracket, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote,
            ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
            "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
        ]
        let letters = [
            kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
            kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
            kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
            kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z,
        ]
        for (letter, code) in zip("abcdefghijklmnopqrstuvwxyz", letters) {
            codes[String(letter)] = code
        }
        let digits = [
            kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
            kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
        ]
        for (digit, code) in zip("0123456789", digits) {
            codes[String(digit)] = code
        }
        return codes
    }()

    static func modifierFlags<Names: Sequence>(for names: Names) throws -> [CGEventFlags]
    where Names.Element: StringProtocol {
        try names.map { name in
            switch name.lowercased() {
            case "command", "cmd": .maskCommand
            case "shift": .maskShift
            case "option", "alt", "opt": .maskAlternate
            case "control", "ctrl": .maskControl
            case "fn": .maskSecondaryFn
            default: throw ComputerUseToolError.unknownModifier(String(name))
            }
        }
    }

    private static func checkAccessibilityPermission() throws {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        guard AXIsProcessTrustedWithOptions(options as CFDictionary) else {
            throw ComputerUseToolError.accessibilityPermissionNotGranted
        }
    }

    /// The key app_find caches an application's element indexes under.
    private static func cacheKey(of app: NSRunningApplication) -> String {
        app.bundleIdentifier ?? String(app.processIdentifier)
    }

    private static func cachedElement(_ index: Int, in app: NSRunningApplication) throws -> AXUIElement {
        guard let element = UIManager.shared.searchElement(appID: cacheKey(of: app), index: index) else {
            throw ComputerUseToolError.uiElementNotFound(index)
        }
        return element
    }

    /// Resolves a pixel of the application's latest screenshot, or of the full screen's
    /// when the application is nil, to a global screen point.
    private static func screenPoint(x: Double?, y: Double?, app: NSRunningApplication?) throws -> CGPoint {
        guard let x, let y else { throw ComputerUseToolError.missingPosition }
        guard let frame = ScreenControlManager.shared.screenshotFrames[app?.processIdentifier ?? 0] else {
            throw ComputerUseToolError.screenshotRequired
        }
        guard let point = frame.screenPoint(x: x, y: y) else {
            throw ComputerUseToolError.outsideScreenshot(frame.size)
        }
        return point
    }

    // MARK: - App Finder

    /// Finds a running application by bundle identifier, name, or bundle file name and brings
    /// it to the front, or opens an installed one.
    static func resolveApp(_ identifier: String) async throws -> NSRunningApplication {
        try Task.checkCancellation()
        let name = identifier.trimmingCharacters(in: .whitespaces)
        func matches(_ candidate: String?) -> Bool {
            candidate?.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }
        if let app = running.first(where: { matches($0.bundleIdentifier) })
            ?? running.first(where: { matches($0.localizedName) })
            ?? running.first(where: { matches($0.bundleURL?.deletingPathExtension().lastPathComponent) }) {
            if !app.isActive {
                app.activate()
                // Keyboard events follow the active application, which changes asynchronously.
                try await Task.sleep(for: .milliseconds(200))
            }
            return app
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name)
                ?? installedApplication(named: name) else {
            throw ComputerUseToolError.appNotFound(identifier)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        // Windows appear shortly after launch.
        try await Task.sleep(for: .seconds(1))
        return app
    }

    private static func installedApplication(named name: String) -> URL? {
        let fileName = name.hasSuffix(".app") ? name : "\(name).app"
        let directories = [
            "/Applications", "/Applications/Utilities", "/System/Applications",
            "/System/Applications/Utilities", "\(NSHomeDirectory())/Applications",
        ]
        return directories
            .map { URL(filePath: $0).appending(path: fileName) }
            .first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }
}


enum ComputerUseToolError: Error, LocalizedError {
    case accessibilityPermissionNotGranted
    case uiElementNotFound(Int)
    case elementHasNoFrame(Int)
    case elementNeedsApp
    case actionFailed(String)
    case appNotFound(String)
    case unknownKey(String)
    case unknownModifier(String)
    case invalidDirection(String)
    case missingPosition
    case screenshotRequired
    case outsideScreenshot(CGSize)
    case menuItemNotFound(String, available: [String])

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionNotGranted:
            "Accessibility permission not granted. Enable in System Settings > Privacy & Security > Accessibility."
        case .uiElementNotFound(let index):
            "Element \(index) is not in the latest app_find of this application. Call app_find again and use a current index."
        case .elementHasNoFrame(let index):
            "Element \(index) has no position on screen. Call app_find again, or use app_screenshot coordinates."
        case .elementNeedsApp:
            "`element` requires `app`, the application its app_find listed it for."
        case .actionFailed(let reason):
            "Action failed: \(reason)"
        case .appNotFound(let name):
            "No running or installed application is named \(name). Call list_apps for the names of running applications."
        case .unknownKey(let keys):
            "`\(keys)` does not name a key. Use names such as `return`, `cmd+a`, or `shift+tab`."
        case .unknownModifier(let name):
            "`\(name)` is not a modifier. Use `cmd`, `shift`, `option`, `ctrl`, or `fn`."
        case .invalidDirection(let direction):
            "`\(direction)` is not a direction. Use `up`, `down`, `left`, or `right`."
        case .missingPosition:
            "Give a position: `element` with `app`, or both `x` and `y` from app_screenshot."
        case .screenshotRequired:
            "There is no screenshot to take coordinates from. Call app_screenshot with the same `app` first."
        case .outsideScreenshot(let size):
            "The position is outside the latest screenshot, which is \(Int(size.width))x\(Int(size.height)) pixels."
        case .menuItemNotFound(let title, let available):
            available.isEmpty
                ? "The menu has no item titled \(title)."
                : "The menu has no item titled \(title). Available: \(available.joined(separator: ", "))."
        }
    }
}

// MARK: - Types

struct RunningAppInfo: Codable {
    let name: String
    let bundleID: String?
    let frontmost: Bool
    let hidden: Bool

    enum CodingKeys: String, CodingKey {
        case name, frontmost, hidden
        case bundleID = "bundle_id"
    }
}

// MARK: - Input/Output Types

struct ListAppsInput: Codable {}

struct OpenAppInput: Codable {
    let app: String
}

struct OpenAppOutput: Codable {
    let name: String
    let bundleID: String?
    let windows: [String]

    enum CodingKeys: String, CodingKey {
        case name, windows
        case bundleID = "bundle_id"
    }
}

struct AppFindInput: Codable {
    let app: String
    let query: String?
    let maxDepth: Int?

    enum CodingKeys: String, CodingKey {
        case app, query
        case maxDepth = "max_depth"
    }
}

struct AppClickInput: Codable {
    let app: String?
    let element: Int?
    let x: Double?
    let y: Double?
    let button: String?
    let clicks: Int?
    let modifiers: [String]?
    let action: String?
}

struct AppTypeInput: Codable {
    let app: String
    let text: String
    let element: Int?
    let replace: Bool?
}

struct AppKeyInput: Codable {
    let app: String
    let keys: String
    let `repeat`: Int?
}

struct AppScrollInput: Codable {
    let app: String?
    let direction: String
    let amount: Int?
    let element: Int?
    let x: Double?
    let y: Double?
}

struct AppDragInput: Codable {
    let app: String?
    let fromX: Double
    let fromY: Double
    let toX: Double
    let toY: Double

    enum CodingKeys: String, CodingKey {
        case app
        case fromX = "from_x"
        case fromY = "from_y"
        case toX = "to_x"
        case toY = "to_y"
    }
}

struct AppMenuInput: Codable {
    let app: String
    let path: [String]
}

struct ActionOutput: Codable {
    let result: String
}
