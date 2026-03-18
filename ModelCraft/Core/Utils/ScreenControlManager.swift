//
//  ScreenControlManager.swift
//  ModelCraft
//
//  Created by Hongshen on 21/2/26.
//

import Foundation
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
import CoreGraphics
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
class ScreenControlManager {
    
    static let shared = ScreenControlManager()
    
    var screen: CGRect {
        #if canImport(AppKit)
        NSScreen.screens
                .map { $0.frame }
                .reduce(CGRect.null) { $0.union($1) }
        #else
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .map { $0.screen.bounds }
            .reduce(CGRect.null) { $0.union($1) }
        #endif
    }

    // MARK: - Screenshot
    func taskScreenshot() -> (Data, String)? {
        #if canImport(AppKit)
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)

        var images: [(CGImage, CGRect)] = []

        for display in displays {
            guard let image = CGDisplayCreateImage(display) else { continue }
            images.append((image, CGDisplayBounds(display)))
        }
        
        guard let ctx = CGContext(
            data: nil,
            width: Int(screen.width),
            height: Int(screen.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        for (image, frame) in images {

            let x = frame.origin.x - screen.origin.x
            let y = frame.origin.y - screen.origin.y

            ctx.draw(image, in: CGRect(x: x, y: y, width: frame.width, height: frame.height))
        }

        guard let merged = ctx.makeImage() else { return nil }
        
        let bitmap = NSBitmapImageRep(cgImage: merged)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }

        return (data, UTType.png.preferredMIMEType!)
        
        #elseif canImport(UIKit)
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) else {
            return nil
        }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let imageData = image.pngData() else { return nil }
        return (imageData, UTType.png.preferredMIMEType!)
        
        #else
        return nil
        #endif
    }
    
    // MARK: - Mouse/Touch Movement
    func move(x: Double, y: Double) {
        let point = screenToSystemPoint(x: x, y: y)
        #if canImport(AppKit)
        let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        moveEvent?.post(tap: .cghidEventTap)
        #elseif canImport(UIKit)
        print("Moving virtual cursor to: \(point)")
        #endif
    }
    
    // MARK: - Click/Tap Action
    func click(x: Double, y: Double) {
        let point = screenToSystemPoint(x: x, y: y)
        #if canImport(AppKit)
        let source = CGEventSource(stateID: .combinedSessionState)
        let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        
        mouseDown?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            mouseUp?.post(tap: .cghidEventTap)
        }
        
        #elseif canImport(UIKit)
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) else {
            return
        }
        
        if let hitView = window.hitTest(point, with: nil) {
            if let button = hitView as? UIButton {
                button.sendActions(for: .touchUpInside)
            } else {
                hitView.gestureRecognizers?.forEach { gesture in
                    if let tap = gesture as? UITapGestureRecognizer {
                        print("Detected tap gesture on: \(type(of: hitView))")
                    }
                }
            }
        }
        #endif
    }
    
    func scroll(deltaY: Int32) {
        #if canImport(AppKit)
        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: deltaY,
            wheel2: 0,
            wheel3: 0
        ) else { return }

        scrollEvent.post(tap: .cghidEventTap)
        #endif
    }
    
    func drag(from: CGPoint, to: CGPoint) {
        let start = screenToSystemPoint(point: from)
        let end = screenToSystemPoint(point: to)
        #if canImport(AppKit)
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

        #endif
    }
    
    func screenToSystemPoint(x: Double, y: Double) -> CGPoint {
        return screenToSystemPoint(point: CGPoint(x: x, y: y))
    }
    
    func screenToSystemPoint(point: CGPoint) -> CGPoint {
        #if canImport(AppKit)
        let height = screen.height
        return CGPoint(x: point.x, y: height - point.y)
        #else
        return CGPoint(x: point.x, y: point.y)
        #endif
    }
}
