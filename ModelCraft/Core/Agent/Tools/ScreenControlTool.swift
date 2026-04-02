//
//  ScreenControlTool.swift
//  ModelCraft
//
//  Created by Hongshen on 31/3/26.
//

import Foundation

import MLXLMCommon
import Tokenizers

class ScreenControlTool {
    
    static var allTools: [ToolSpec] {
        var tools = [
            captureScreen.schema,
            click.schema,
            move.schema,
            drag.schema,
            scroll.schema,
        ]
        return tools
    }
    
    static let captureScreen = Tool<CaptureScreenInput, CaptureScreenOutput?>(
        name: "capture_screen",
        description: "Takes a high-resolution screenshot of the current screen to analyze the UI layout and identify element coordinates.",
        parameters: []
    ) { input in
        print("Capturing screen...")
        guard let (imageData, mimeType) = await ScreenControlManager.shared.taskScreenshot() else { return nil }
        print("Capturing screen succeed.")
        return CaptureScreenOutput(imageData: imageData, mimeType: mimeType)
    }
    
    static let click = Tool<ClickInput, ClickOutput>(
        name: "click",
        description: "Performs a mouse click at the specified (x, y) coordinates. Coordinates should be based on the screenshot provided.",
        parameters: [
            .required("x", type: .double, description: "The target x coordinate."),
            .required("y", type: .double, description: "The target y coordinate.")
        ]
    ) { input in
        await ScreenControlManager.shared.click(x: input.x, y: input.y)
        return ClickOutput()
    }
    
    static let move = Tool<MoveInput, MoveOutput>(
        name: "move",
        description: "Moves the mouse cursor to a specific (x, y) location.",
        parameters: [
            .required("x", type: .double, description: "The target x coordinate."),
            .required("y", type: .double, description: "The target y coordinate.")
        ]
    ) { input in
        await ScreenControlManager.shared.move(x: input.x, y: input.y)
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
        await ScreenControlManager.shared.drag(
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
        await ScreenControlManager.shared.scroll(deltaY: input.deltaY)
        return ScrollOutput()
    }
}

struct CaptureScreenInput: Codable {}

struct CaptureScreenOutput: Codable {
    let imageData: Data
    let mimeType: String
}

struct MoveInput: Codable {
    let x: Double
    let y: Double
}

struct MoveOutput: Codable {}

struct ClickInput: Codable {
    let x: Double
    let y: Double
}

struct ClickOutput: Codable {}

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
