//
//  QuickEntry.swift
//  ModelCraft
//

import AppKit
import KeyboardShortcuts
import SwiftUI

/// The panel a system-wide shortcut opens over any app. It reads what the user was looking
/// at, takes a typed or spoken request, and sends both as a new thread in the main window.
///
/// The panel does not activate ModelCraft, so the other app stays frontmost while its
/// selection is read, and clicking anywhere else closes it.
@MainActor
final class QuickEntry: NSObject, NSWindowDelegate {

    private let globalStore: GlobalStore
    private let sttService: STTService
    private var openMainWindow: () -> Void = {}
    private var hasStarted = false
    private var panel: NSPanel?
    /// The panel's top centre, kept while its height follows the content.
    private var anchor = NSPoint.zero

    init(globalStore: GlobalStore, sttService: STTService) {
        self.globalStore = globalStore
        self.sttService = sttService
    }

    /// Registers the shortcut once. KeyboardShortcuts tracks changes from Settings.
    /// `openMainWindow` opens a main window when none is open.
    func start(openMainWindow: @escaping () -> Void) {
        guard !hasStarted else { return }
        hasStarted = true
        self.openMainWindow = openMainWindow
        KeyboardShortcuts.onKeyDown(for: .quickEntry) { [weak self] in
            self?.toggle()
        }
    }

    private func toggle() {
        if panel?.isVisible == true {
            close()
        } else {
            show()
        }
    }

    private func show() {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let sourceApp = frontmostApp?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : frontmostApp
        let selection = sourceApp.map { QuickEntryContext.selection(from: $0) } ?? QuickEntryContext()
        let panel = panel ?? makePanel()
        self.panel = panel

        // A new view each time starts from an empty request and a fresh context.
        let controller = NSHostingController(rootView: QuickEntryView(
            sourceApp: sourceApp,
            selection: selection,
            onSubmit: { [weak self] in self?.submit($0, files: $1) },
            onClose: { [weak self] in self?.close() }
        )
        .environment(sttService)
        .applyUserSettings())
        controller.sizingOptions = .preferredContentSize
        panel.contentViewController = controller

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            anchor = NSPoint(x: frame.midX, y: frame.maxY - frame.height / 5)
        }
        placePanel()
        panel.makeKeyAndOrderFront(nil)
    }

    private func close() {
        guard let panel, let controller = panel.contentViewController else { return }
        panel.orderOut(nil)
        // Releasing the view cancels its recording and context capture. It happens after the
        // current event, since closing can come from the view's own action.
        DispatchQueue.main.async {
            if panel.contentViewController === controller {
                panel.contentViewController = nil
            }
        }
    }

    private func submit(_ message: String, files: [URL]) {
        close()
        globalStore.startNewThread()
        globalStore.newThreadPrompt = .init(content: message, files: files)
        NSApp.activate()
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix(ModelCraftApp.mainWindowID) == true
        }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = KeyPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        return panel
    }

    private func placePanel() {
        guard let panel else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height))
    }

    func windowDidResize(_ notification: Notification) {
        placePanel()
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// A borderless panel cannot become key by default, and Quick Entry takes typing.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
