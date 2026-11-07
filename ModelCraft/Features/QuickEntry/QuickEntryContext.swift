//
//  QuickEntryContext.swift
//  ModelCraft
//

import AppKit
import ApplicationServices

/// What the user was looking at when Quick Entry opened: the items selected in Finder, the
/// page open in a browser, and text selected in the app.
struct QuickEntryContext {

    struct Page {
        let title: String
        let url: URL
    }

    /// The app the context was read from.
    var appName = ""
    var files: [URL] = []
    var page: Page?
    var selectedText: String?
    var image: Page?

    private static let finderBundleID = "com.apple.finder"
    private static let safariBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
    ]
    private static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser",
    ]

    /// Reads the context from `app`, the app that was active when Quick Entry opened. Runs off
    /// the main actor, because AppleScript waits for the app to answer. Anything the app does
    /// not offer, or the user has not allowed, is left out.
    static func capture(from app: NSRunningApplication, selection: QuickEntryContext) async -> QuickEntryContext {
        var context = selection
        guard let bundleID = app.bundleIdentifier else { return context }
        if bundleID == finderBundleID {
            context.files = await finderSelection()
            return context
        }
        if safariBundleIDs.contains(bundleID) {
            context.page = await page(in: bundleID, source: """
                tell application id "\(bundleID)" to tell front window
                    return {name of current tab, URL of current tab}
                end tell
                """)
        } else if chromiumBundleIDs.contains(bundleID) {
            context.page = await page(in: bundleID, source: """
                tell application id "\(bundleID)" to tell front window
                    return {title of active tab, URL of active tab}
                end tell
                """)
        }
        return context
    }

    /// Snapshot selection before the panel takes keyboard focus or covers the pointer.
    static func selection(from app: NSRunningApplication) -> QuickEntryContext {
        var context = QuickEntryContext(appName: app.localizedName ?? "")
        context.selectedText = selectedText(in: app)
        guard AXIsProcessTrusted(), let desktop = NSScreen.screens.first else { return context }
        let pointer = NSEvent.mouseLocation
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            application, Float(pointer.x), Float(desktop.frame.maxY - pointer.y), &hit
        ) == .success else { return context }
        var element = hit
        for _ in 0..<5 {
            guard let current = element else { break }
            if current.role == kAXImageRole {
                let url: URL? = current.getAttribute(kAXURLAttribute)
                    ?? (current.getAttribute(kAXURLAttribute) as String?).flatMap(URL.init(string:))
                if let url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                    context.image = Page(
                        title: current.description ?? current.title ?? url.lastPathComponent,
                        url: url)
                }
                break
            }
            element = current.parent
        }
        return context
    }

    /// The selected items, or the front window's folder when nothing is selected.
    private static func finderSelection() async -> [URL] {
        let source = """
            tell application "Finder"
                set thePaths to {}
                repeat with theItem in (selection as alias list)
                    set end of thePaths to POSIX path of theItem
                end repeat
                if thePaths is {} and (count of Finder windows) > 0 then
                    set end of thePaths to POSIX path of (target of front Finder window as alias)
                end if
                return thePaths
            end tell
            """
        guard let result = try? await AppleScriptRunner.run(source, in: finderBundleID) else { return [] }
        return AppleScriptRunner.items(of: result)
            .compactMap(\.stringValue)
            .map { URL(fileURLWithPath: $0) }
    }

    private static func page(in bundleID: String, source: String) async -> Page? {
        guard let result = try? await AppleScriptRunner.run(source, in: bundleID) else { return nil }
        let values = AppleScriptRunner.items(of: result).compactMap(\.stringValue)
        guard values.count == 2, let url = URL(string: values[1]), url.scheme != nil else { return nil }
        return Page(title: values[0].isEmpty ? values[1] : values[0], url: url)
    }

    /// The focused element's selected text, read through Accessibility when it is allowed.
    private static func selectedText(in app: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused: AXUIElement = application.getAttribute(kAXFocusedUIElementAttribute),
              let text: String = focused.getAttribute(kAXSelectedTextAttribute)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The request followed by the context, as the message Quick Entry sends. Files are listed
    /// by path, not attached, so the agent works on them where they are.
    func message(for request: String) -> String {
        var sections = [request]
        if !files.isEmpty {
            sections.append(String(localized: "Selected in \(appName):") + "\n"
                + files.map { "- \($0.path)" }.joined(separator: "\n"))
        }
        if let page {
            sections.append(String(localized: "Open in \(appName):") + " [\(page.title)](\(page.url.absoluteString))")
        }
        if let selectedText {
            sections.append(String(localized: "Selected in \(appName):") + "\n"
                + selectedText.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> \($0)" }.joined(separator: "\n"))
        }
        if let image {
            sections.append(String(localized: "Image in \(appName):")
                + " [\(image.title)](\(image.url.absoluteString))")
        }
        return sections.joined(separator: "\n\n")
    }
}
