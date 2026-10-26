//
//  ScreenControlManager.swift
//  ModelCraft
//
//  Created by Hongshen on 21/2/26.
//


import Foundation
import UniformTypeIdentifiers
import CoreGraphics

import AppKit
import ScreenCaptureKit


final class ScreenControlManager {

    static let shared = ScreenControlManager()

    /// The longer side of a screenshot in pixels. Vision models downscale larger images
    /// themselves, which makes the coordinates they read off them imprecise.
    static let maxScreenshotEdge: CGFloat = 1280

    /// The latest screenshot of each application, keyed by process identifier, and of all
    /// displays under 0. Coordinates the model reads off a screenshot resolve against it.
    private(set) var screenshotFrames: [pid_t: ScreenshotFrame] = [:]

    // MARK: - Screenshot

    /// Captures the application's on-screen windows, and nothing else, on the display that
    /// shows most of its largest window; captures all displays when the application is nil.
    func screenshot(of app: NSRunningApplication?) async throws -> CGImage {
        try Task.checkCancellation()
        let content = try await SCShareableContent.current
        try Task.checkCancellation()
        guard let app else { return try await screenshotOfAllDisplays(content) }

        let windows = content.windows.filter {
            $0.owningApplication?.processID == app.processIdentifier
                && $0.isOnScreen && $0.frame.width > 1 && $0.frame.height > 1
        }
        guard let largest = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let display = content.displays.max(by: {
                  $0.frame.intersection(largest.frame).area < $1.frame.intersection(largest.frame).area
              })
        else { throw ScreenControlError.noWindows }

        let shown = windows.filter { $0.frame.intersects(display.frame) }
        let rect = shown.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            .intersection(display.frame).integral
        let scale = min(1, Self.maxScreenshotEdge / max(rect.width, rect.height))
        let config = SCStreamConfiguration()
        config.sourceRect = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = Int((rect.width * scale).rounded())
        config.height = Int((rect.height * scale).rounded())
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, including: shown),
            configuration: config)
        screenshotFrames[app.processIdentifier] = ScreenshotFrame(
            origin: rect.origin, scale: scale,
            size: CGSize(width: image.width, height: image.height))
        return image
    }

    private func screenshotOfAllDisplays(_ content: SCShareableContent) async throws -> CGImage {
        guard !content.displays.isEmpty else { throw ScreenControlError.noWindows }
        let captureFrame = content.displays
            .map(\.frame)
            .reduce(CGRect.null) { $0.union($1) }
        let scale = min(1, Self.maxScreenshotEdge / max(captureFrame.width, captureFrame.height))
        let cursorWindows = content.windows.filter { $0.windowID == VirtualCursor.windowID }

        // Capture each display concurrently at the screenshot's scale
        var captures: [(image: CGImage, frame: CGRect)] = []
        try await withThrowingTaskGroup(of: (CGImage, CGRect).self) { group in
            for display in content.displays {
                group.addTask {
                    try Task.checkCancellation()
                    let config = SCStreamConfiguration()
                    config.width = Int((display.frame.width * scale).rounded())
                    config.height = Int((display.frame.height * scale).rounded())
                    config.showsCursor = false
                    config.colorSpaceName = CGColorSpace.sRGB
                    let filter = SCContentFilter(display: display, excludingWindows: cursorWindows)
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    return (image, display.frame)
                }
            }
            for try await result in group {
                captures.append(result)
            }
        }
        try Task.checkCancellation()

        let width = Int((captureFrame.width * scale).rounded())
        let height = Int((captureFrame.height * scale).rounded())
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ScreenControlError.captureFailed }

        // Fill background black to cover any gaps between non-contiguous displays
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        for (image, frame) in captures {
            let destX = frame.minX - captureFrame.minX
            let destY = captureFrame.maxY - frame.maxY
            ctx.draw(image, in: CGRect(x: destX, y: destY, width: frame.width, height: frame.height))
        }
        guard let image = ctx.makeImage() else { throw ScreenControlError.captureFailed }
        screenshotFrames[0] = ScreenshotFrame(
            origin: captureFrame.origin, scale: scale,
            size: CGSize(width: width, height: height))
        return image
    }

    /// Captures a rectangle in global screen points at up to its display's native pixel
    /// density. It records no screenshot frame: the image is for reading, not for coordinates.
    func zoom(into rect: CGRect) async throws -> CGImage {
        try Task.checkCancellation()
        let content = try await SCShareableContent.current
        try Task.checkCancellation()
        guard let display = content.displays.max(by: {
            $0.frame.intersection(rect).area < $1.frame.intersection(rect).area
        }) else { throw ScreenControlError.captureFailed }
        let region = rect.intersection(display.frame)
        guard !region.isNull, region.width >= 1, region.height >= 1 else {
            throw ScreenControlError.captureFailed
        }
        let filter = SCContentFilter(
            display: display,
            excludingWindows: content.windows.filter { $0.windowID == VirtualCursor.windowID })
        let scale = min(
            CGFloat(filter.pointPixelScale),
            Self.maxScreenshotEdge / max(region.width, region.height))
        let config = SCStreamConfiguration()
        config.sourceRect = region.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = Int((region.width * scale).rounded())
        config.height = Int((region.height * scale).rounded())
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: - Virtual Pointer

    /// Where the agent's pointer is, in global screen points. Mouse actions post events
    /// directly to the process that owns the window under this point, so the user's real
    /// cursor never moves.
    private(set) var pointer: CGPoint = CGEvent(source: nil)?.location ?? .zero

    private let eventSource = CGEventSource(stateID: .privateState)

    // MARK: - Click Action
    func click(
        at point: CGPoint,
        button: CGMouseButton = .left,
        count: Int = 1,
        modifiers: CGEventFlags = []
    ) async {
        await moveVirtualPointer(to: point)
        guard let target = windowTarget(at: point) else { return }
        await activate(target)
        let (down, up): (CGEventType, CGEventType) = button == .right
            ? (.rightMouseDown, .rightMouseUp)
            : (.leftMouseDown, .leftMouseUp)
        // Each press of a multiple click carries its running click count, as the window server's do.
        for clickState in 1...max(count, 1) {
            post(down, at: point, to: target, button: button, clickState: clickState, flags: modifiers)
            try? await Task.sleep(for: .milliseconds(50))
            post(up, at: point, to: target, button: button, clickState: clickState, flags: modifiers)
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Scrolls the window under the point; positive deltas scroll up and left.
    func scroll(at point: CGPoint, deltaX: Int32, deltaY: Int32) async {
        await moveVirtualPointer(to: point)
        guard let target = windowTarget(at: point),
              let scrollEvent = CGEvent(
                scrollWheelEvent2Source: eventSource,
                units: .pixel,
                wheelCount: 2,
                wheel1: deltaY,
                wheel2: deltaX,
                wheel3: 0
              ) else { return }
        scrollEvent.location = point
        scrollEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowID))
        scrollEvent.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.windowID))
        scrollEvent.postToPid(target.pid)
    }

    func pressKey(keyCode: CGKeyCode, modifiers: [CGEventFlags] = []) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        
        let finalFlags = modifiers.reduce(CGEventFlags()) { $0.union($1) }
        var modifierDownEvents: [CGEvent] = []
        for modifier in modifiers {
            modifierDownEvents.append(CGEvent(keyboardEventSource: source, virtualKey: getVirtualKey(for: modifier), keyDown: true)!)
        }
        
        let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDownEvent?.flags = finalFlags
        let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUpEvent?.flags = finalFlags
        
        for event in modifierDownEvents {
            event.post(tap: .cghidEventTap)
        }
        keyDownEvent?.post(tap: .cghidEventTap)
        keyUpEvent?.post(tap: .cghidEventTap)
        
        for modifier in modifiers.reversed() {
            if let event = CGEvent(keyboardEventSource: source, virtualKey: getVirtualKey(for: modifier), keyDown: false) {
                event.post(tap: .cghidEventTap)
            }
        }
    }
    
    func getVirtualKey(for flag: CGEventFlags) -> CGKeyCode {
        switch flag {
        case .maskCommand:   return 0x37 // Left Cmd
        case .maskAlternate: return 0x3A // Left Option
        case .maskShift:     return 0x38 // Left Shift
        case .maskControl:   return 0x3B // Left Control
        case .maskSecondaryFn: return 0x3F // Fn
        default:             return 0
        }
    }
    
    func drag(from start: CGPoint, to end: CGPoint) async {
        await moveVirtualPointer(to: start)
        guard let target = windowTarget(at: start) else { return }
        await activate(target)
        post(.leftMouseDown, at: start, to: target)

        // Intermediate drag events let the target track the gesture like a real drag.
        let steps = 10
        for step in 1...steps {
            let fraction = Double(step) / Double(steps)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction
            )
            try? await Task.sleep(for: .milliseconds(16))
            pointer = point
            await VirtualCursor.shared.show(at: point, animated: false)
            post(.leftMouseDragged, at: point, to: target)
        }
        post(.leftMouseUp, at: end, to: target)
    }

    /// Types a string character-by-character using Unicode key events (handles any character,
    /// not just keyboard-mappable ones). Line breaks and tabs are sent as Return and Tab key
    /// presses, which is what text views and forms act on.
    func typeString(_ string: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for character in string {
            guard !Task.isCancelled else { return }
            switch character {
            case "\n", "\r\n", "\r":
                pressKey(keyCode: 0x24)
                continue
            case "\t":
                pressKey(keyCode: 0x30)
                continue
            default:
                break
            }
            let utf16Char = [UniChar](String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }

            down.keyboardSetUnicodeString(stringLength: utf16Char.count, unicodeString: utf16Char)
            up.keyboardSetUnicodeString(stringLength: utf16Char.count, unicodeString: utf16Char)

            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
    
    // MARK: - Event Targeting

    private struct WindowTarget {
        let pid: pid_t
        let windowID: CGWindowID
    }

    /// The front-most on-screen window containing the point, excluding the virtual cursor.
    private func windowTarget(at point: CGPoint) -> WindowTarget? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[CFString: Any]] else { return nil }
        let cursorWindowID = VirtualCursor.windowID
        for window in windows {
            guard let windowID = window[kCGWindowNumber] as? CGWindowID,
                  windowID != cursorWindowID,
                  let pid = window[kCGWindowOwnerPID] as? pid_t,
                  (window[kCGWindowAlpha] as? Double ?? 1) > 0,
                  let boundsDictionary = window[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.contains(point) else { continue }
            return WindowTarget(pid: pid, windowID: windowID)
        }
        return nil
    }

    /// Brings the target app forward, as a real click would, so later key events reach it.
    private func activate(_ target: WindowTarget) async {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isActive else { return }
        app.activate(options: [])
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func post(
        _ type: CGEventType,
        at point: CGPoint,
        to target: WindowTarget,
        button: CGMouseButton = .left,
        clickState: Int = 1,
        flags: CGEventFlags = []
    ) {
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { return }
        if type != .mouseMoved {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        }
        event.flags = flags
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.windowID))
        event.postToPid(target.pid)
    }

    private func moveVirtualPointer(to point: CGPoint) async {
        pointer = point
        await VirtualCursor.shared.show(at: point, animated: true)
    }
}

/// The on-screen indicator for the agent's virtual pointer. It ignores mouse events and is
/// excluded from captures, so it never intercepts clicks or appears in screenshots.
@MainActor
final class VirtualCursor {

    static let shared = VirtualCursor()

    /// Read by capture and hit-testing code off the main actor without creating the panel.
    nonisolated(unsafe) private(set) static var windowID: CGWindowID = kCGNullWindowID

    private let panel: NSPanel
    private let hotSpot: CGPoint
    private var hideTask: Task<Void, Never>?

    private init() {
        let image = NSCursor.arrow.image
        hotSpot = NSCursor.arrow.hotSpot
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: image.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let imageView = NSImageView(image: image)
        imageView.frame = CGRect(origin: .zero, size: image.size)
        imageView.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = .controlAccentColor
            shadow.shadowBlurRadius = 6
            return shadow
        }()
        panel.contentView = imageView
        Self.windowID = CGWindowID(panel.windowNumber)
    }

    /// Shows the cursor with its hot spot at a global screen point (top-left origin).
    func show(at point: CGPoint, animated: Bool) async {
        hideTask?.cancel()
        let frame = CGRect(origin: cocoaOrigin(for: point), size: panel.frame.size)
        if animated && panel.isVisible {
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
        }
        Self.windowID = CGWindowID(panel.windowNumber)
        hideTask = Task { [panel] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }

    private func cocoaOrigin(for point: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(
            x: point.x - hotSpot.x,
            y: primaryHeight - point.y - (panel.frame.height - hotSpot.y)
        )
    }
}


/// Where a screenshot sits on screen, so a pixel the model reads off it maps back to a
/// global screen point.
struct ScreenshotFrame {
    /// The global screen point at the image's top-left corner.
    let origin: CGPoint
    /// Image pixels per screen point.
    let scale: CGFloat
    /// The image size in pixels.
    let size: CGSize

    /// The global screen point under a pixel, or nil when the pixel is outside the image.
    func screenPoint(x: Double, y: Double) -> CGPoint? {
        guard (0...size.width).contains(x), (0...size.height).contains(y) else { return nil }
        return CGPoint(x: origin.x + x / scale, y: origin.y + y / scale)
    }
}

enum ScreenControlError: LocalizedError {
    case noWindows
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .noWindows:
            "The application has no windows on screen. Open a window, or use open_app to bring the application forward, and try again."
        case .captureFailed:
            "The screen could not be captured."
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
