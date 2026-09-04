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
        description: "Capture all displays as one screenshot for visual context or global screen coordinates. Use capture_app_window for a known application, or get_ui_hierarchy when semantic labels and actionable element indexes are needed. Returns image data, MIME type, and total size in screen points.",
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
        description: "Capture every visible window of one application for visual layout, state, and global screen coordinates. Use get_ui_hierarchy instead when semantic labels or actionable element indexes are needed. Returns each window's image, identifier, and frame in screen points.",
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
        description: "Move the pointer to a global screen coordinate without clicking. Obtain coordinates from a recent screen or application-window capture.",
        parameters: [
            .required("x", type: .double, description: "Horizontal coordinate in global screen points."),
            .required("y", type: .double, description: "Vertical coordinate in global screen points.")
        ]
    ) { input in
        ScreenControlManager.shared.move(x: input.x, y: input.y)
        return MoveOutput(success: true)
    }
    
    static let drag = Tool<DragInput, DragOutput>(
        name: "drag",
        description: "Press at one global screen coordinate and drag to another. Use recent visual coordinates when semantic accessibility actions are unavailable, then capture or inspect the application again to verify the resulting state.",
        parameters: [
            .required("startX", type: .double, description: "Starting horizontal coordinate in global screen points."),
            .required("startY", type: .double, description: "Starting vertical coordinate in global screen points."),
            .required("endX", type: .double, description: "Destination horizontal coordinate in global screen points."),
            .required("endY", type: .double, description: "Destination vertical coordinate in global screen points.")
        ]
    ) { input in
        ScreenControlManager.shared.drag(
            from: CGPoint(x: input.startX, y: input.startY),
            to: CGPoint(x: input.endX, y: input.endY)
        )
        return DragOutput(success: true)
    }
    
    static let scroll = Tool<ScrollInput, ScrollOutput>(
        name: "scroll",
        description: "Scroll vertically in the application under the current pointer. Position the pointer over the intended scroll area first, then capture or inspect the application again to verify the resulting state.",
        parameters: [
            .required("deltaY", type: .int, description: "Scroll amount in pixels. Negative scrolls down, positive scrolls up.")
        ]
    ) { input in
        ScreenControlManager.shared.scroll(deltaY: input.deltaY)
        return ScrollOutput(success: true)
    }
    
    
    static let click = Tool<ClickInput, ClickOutput>(
        name: "click",
        description: "Click one global screen coordinate. Use a current visual capture when a semantic click_element action is unavailable, then capture or inspect the application again to verify the resulting state.",
        parameters: [
            .required("x", type: .double, description: "Horizontal coordinate in global screen points."),
            .required("y", type: .double, description: "Vertical coordinate in global screen points.")
        ]
    ) { input in
        ScreenControlManager.shared.click(x: input.x, y: input.y)
        return ClickOutput(success: true)
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

struct ClickOutput: Codable {
    let success: Bool
}

struct MoveInput: Codable {
    let x: Double
    let y: Double
}

struct MoveOutput: Codable {
    let success: Bool
}

struct DragInput: Codable {
    let startX: Double
    let startY: Double
    let endX: Double
    let endY: Double
}

struct DragOutput: Codable {
    let success: Bool
}

struct ScrollInput: Codable {
    let deltaY: Int32
}

struct ScrollOutput: Codable {
    let success: Bool
}
