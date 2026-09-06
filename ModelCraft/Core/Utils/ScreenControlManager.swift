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

    var screen: CGRect {
        NSScreen.screens
                .map { $0.frame }
                .reduce(CGRect.null) { $0.union($1) }
    }

    // MARK: - Screenshot
    func takeFullScreenshot() async throws -> FullScreenshot? {
        try Task.checkCancellation()
        let content = try await SCShareableContent.current
        try Task.checkCancellation()
        guard !content.displays.isEmpty else { return nil }
        let captureFrame = content.displays
            .map(\.frame)
            .reduce(CGRect.null) { $0.union($1) }

        // Capture each display concurrently at its native point-space resolution
        var captures: [(image: CGImage, frame: CGRect)] = []

        try await withThrowingTaskGroup(of: (CGImage, CGRect).self) { group in
            for display in content.displays {
                group.addTask {
                    try Task.checkCancellation()
                    let config = SCStreamConfiguration()
                    config.width = display.width
                    config.height = display.height
                    config.showsCursor = false
                    config.colorSpaceName = CGColorSpace.sRGB

                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    try Task.checkCancellation()
                    return (image, display.frame)
                }
            }
            for try await result in group {
                try Task.checkCancellation()
                captures.append(result)
            }
        }

        guard !captures.isEmpty else { return nil }

        guard let ctx = CGContext(
            data: nil,
            width: Int(captureFrame.width.rounded()),
            height: Int(captureFrame.height.rounded()),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Fill background black to cover any gaps between non-contiguous displays
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: captureFrame.width, height: captureFrame.height))

        for (image, frame) in captures {
            try Task.checkCancellation()
            let destX = frame.minX - captureFrame.minX
            let destY = captureFrame.maxY - frame.maxY

            let destRect = CGRect(x: destX, y: destY, width: frame.width, height: frame.height)
            ctx.draw(image, in: destRect)
        }
        return FullScreenshot(image: ctx.makeImage()!, size: captureFrame.size)
    }

    // MARK: - App Window Screenshot
    func takeAppWindowScreenshot(appID: String) async throws -> [AppWindowScreenshot] {
        try Task.checkCancellation()
        let content = try await SCShareableContent.current
        try Task.checkCancellation()
        guard !content.displays.isEmpty else { return [] }
        
        let targetWindows = content.windows.filter { window in
            guard let owningApp = window.owningApplication else { return false }
            return owningApp.bundleIdentifier == appID &&
                   window.isOnScreen
        }
        
        guard !targetWindows.isEmpty else {
            return []
        }
        
        var results: [AppWindowScreenshot] = []

        for window in targetWindows {
            try Task.checkCancellation()
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            
            config.width = Int(window.frame.width)
            config.height = Int(window.frame.height)
            config.showsCursor = false
            
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                try Task.checkCancellation()
                results.append(AppWindowScreenshot(
                    image: image,
                    windowFrame: window.frame,
                    windowID: Int(window.windowID)
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return results
    }
    
    // MARK: - Mouse Movement
    func move(x: Double, y: Double) {
        let point = screenToSystemPoint(x: x, y: y)
        let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        moveEvent?.post(tap: .cghidEventTap)
    }

    // MARK: - Click Action
    func click(at: CGPoint) {
        let point = screenToSystemPoint(point: at)
        let source = CGEventSource(stateID: .combinedSessionState)
        let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)

        mouseDown?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            mouseUp?.post(tap: .cghidEventTap)
        }
    }
    
    func click(x: Double, y: Double) {
        click(at: CGPoint(x: x, y: y))
    }

    func scroll(deltaY: Int32) {
        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: deltaY,
            wheel2: 0,
            wheel3: 0
        ) else { return }

        scrollEvent.post(tap: .cghidEventTap)
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
        default:             return 0
        }
    }
    
    func drag(from: CGPoint, to: CGPoint) {
        let start = screenToSystemPoint(point: from)
        let end = screenToSystemPoint(point: to)
        let source = CGEventSource(stateID: .combinedSessionState)

        CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: start,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)

        CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: end,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)

        CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: end,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    /// Types a string character-by-character using Unicode key events (handles any character, not just keyboard-mappable ones)
    func typeString(_ string: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for scalar in string.unicodeScalars {
            guard !Task.isCancelled else { return }
            let utf16Char = [UniChar](String(scalar).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }

            down.keyboardSetUnicodeString(stringLength: utf16Char.count, unicodeString: utf16Char)
            up.keyboardSetUnicodeString(stringLength: utf16Char.count, unicodeString: utf16Char)

            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
    
    func screenToSystemPoint(x: Double, y: Double) -> CGPoint {
        return screenToSystemPoint(point: CGPoint(x: x, y: y))
    }

    func screenToSystemPoint(point: CGPoint) -> CGPoint {
        point
    }
}

struct FullScreenshot {
    let image: CGImage
    let size: CGSize
}

struct AppWindowScreenshot {
    let image: CGImage
    let windowFrame: CGRect
    let windowID: Int
}
