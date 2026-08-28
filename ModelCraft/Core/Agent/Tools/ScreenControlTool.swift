//
//  ScreenControlTool.swift
//  ModelCraft
//
//  Created by Hongshen on 31/3/26.
//

import Foundation
import UniformTypeIdentifiers

import MLXLMCommon

class ScreenControlTool {
    
    static let allTools: [any ToolProtocol] = [
        captureFullScreen,
        captureAppWindow,
        click,
        move,
        drag,
        scroll,
    ]
    
    static let captureFullScreen = Tool<CaptureFullScreenInput, CaptureFullScreenOutput?>(
        name: "capture_full_screen",
        description: "Capture full screenshot of all displays.",
        parameters: []
    ) { input in
        guard let screenshot = try await ScreenControlManager.shared.takeFullScreenshot() else { return nil }
        guard let data = screenshot.image.data(type: .png) else {
            return nil
        }
        return CaptureFullScreenOutput(
            imageData: data,
            mimeType: UTType.png.preferredMIMEType!,
            size: screenshot.size)
    }
    
    static let captureAppWindow = Tool<CaptureAppWindowInput, [AppWindow]>(
        name: "capture_app_window",
        description: "Capture all windows of a specific application.",
        parameters: [
            .required("appID", type: .string, description: "The bundle identifier of the target app (e.g., com.apple.Finder)")
        ]
    ) { input in
        
        let windows = try await ScreenControlManager.shared.takeAppWindowScreenshot(appID: input.appID)
        
        var results: [AppWindow] = []
        for window in windows {
            guard let data = window.image.data(type: .png) else {
                continue
            }
            results.append(
                AppWindow(
                    imageData: data,
                    mimeType: UTType.png.preferredMIMEType!,
                    windowFrame: window.windowFrame,
                    windowID: window.windowID))
        }
        return results
    }
    
    
    static let move = Tool<MoveInput, MoveOutput>(
        name: "move",
        description: "Moves the mouse cursor to a specific (x, y) location.",
        parameters: [
            .required("x", type: .double, description: "The target x coordinate."),
            .required("y", type: .double, description: "The target y coordinate.")
        ]
    ) { input in
        ScreenControlManager.shared.move(x: input.x, y: input.y)
        return MoveOutput()
    }
    
    static let drag = Tool<DragInput, DragOutput>(
        name: "drag",
        description: "Presses the mouse at a starting point and drags it to another location.",
        parameters: [
            .required("startX", type: .double, description: "The starting x coordinate."),
            .required("startY", type: .double, description: "The starting y coordinate."),
            .required("endX", type: .double, description: "The destination x coordinate."),
            .required("endY", type: .double, description: "The destination y coordinate.")
        ]
    ) { input in
        ScreenControlManager.shared.drag(
            from: CGPoint(x: input.startX, y: input.startY),
            to: CGPoint(x: input.endX, y: input.endY)
        )
        return DragOutput()
    }
    
    static let scroll = Tool<ScrollInput, ScrollOutput>(
        name: "scroll",
        description: "Scrolls vertically at the current cursor position.",
        parameters: [
            .required("deltaY", type: .int, description: "Scroll amount in pixels. Negative scrolls down, positive scrolls up.")
        ]
    ) { input in
        ScreenControlManager.shared.scroll(deltaY: input.deltaY)
        return ScrollOutput()
    }
    
    
    static let click = Tool<ClickInput, ClickOutput>(
        name: "click",
        description: "click at a specific (x, y) location.",
        parameters: [
            .required("x", type: .double, description: "The target x coordinate."),
            .required("y", type: .double, description: "The target y coordinate.")
        ]
    ) { input in
        ScreenControlManager.shared.click(x: input.x, y: input.y)
        return ClickOutput()
    }
}

struct CaptureFullScreenInput: Codable {}

struct CaptureFullScreenOutput: Codable {
    let imageData: Data
    let mimeType: String
    let size: CGSize
}

struct CaptureAppWindowInput: Codable {
    let appID: String
}

struct CaptureAppWindowOutput: Codable {
    
}

struct AppWindow: Codable {
    let imageData: Data
    let mimeType: String
    let windowFrame: CGRect
    let windowID: Int
}

struct ClickInput: Codable {
    let x: Double
    let y: Double
}

struct ClickOutput: Codable {}

struct MoveInput: Codable {
    let x: Double
    let y: Double
}

struct MoveOutput: Codable {}

struct DragInput: Codable {
    let startX: Double
    let startY: Double
    let endX: Double
    let endY: Double
}

struct DragOutput: Codable {}

struct ScrollInput: Codable {
    let deltaY: Int32
}

struct ScrollOutput: Codable {}
