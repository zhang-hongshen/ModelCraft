//
//  ScreenControlManager.swift
//  ModelCraft
//
//  Created by Hongshen on 21/2/26.
//

import Foundation
import CoreGraphics
import AppKit
import UniformTypeIdentifiers

@MainActor
class ScreenControlManager {
    
    static let shared = ScreenControlManager()
    
    private var screenSize: CGSize {
        NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
    }

    func taskScreenshot() -> (Data, String)? {
        guard let image = CGDisplayCreateImage(CGMainDisplayID())
        else { return nil }
        
        let bitmap = NSBitmapImageRep(cgImage: image)
        
        guard let imageData = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        
        return (imageData, UTType.png.preferredMIMEType!)
    }
    
    func move(x: Double, y: Double) {
        return move(x: CGFloat(x), y: CGFloat(y))
    }
    
    func move(to x: CGFloat, y: CGFloat) {
        let point = CGPoint(x: x, y: y)
        let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        moveEvent?.post(tap: .cghidEventTap)
    }
    
    func click(x: Double, y: Double) {
        return click(x: CGFloat(x), y: CGFloat(y))
    }
    
    func click(x: CGFloat, y: CGFloat) {
        let point = CGPoint(x: x, y: y)
        let source = CGEventSource(stateID: .combinedSessionState)
        
        let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        
        mouseDown?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            mouseUp?.post(tap: .cghidEventTap)
        }
    }
}
