//
//  ScreenControlTool.swift
//  ModelCraft
//
//  Created by Hongshen on 31/3/26.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

import MLXLMCommon

enum ScreenControlTool {

    static let allTools: [any ToolProtocol] = [
        appScreenshot,
        appZoom,
    ]

    static let appScreenshot = Tool<AppScreenshotInput, ScreenshotOutput>(
        name: ToolNames.appScreenshot,
        description: "Take a screenshot of an application's windows, or of all displays when `app` is omitted, to see visual state, layout, and content that app_find does not expose. An application screenshot shows only its own windows, including its open menus and sheets. The image is at most 1280 pixels on its longer side. The `x` and `y` parameters of app_click, app_scroll, app_drag, and app_zoom are pixels of the latest screenshot taken with the same `app`, measured from its top-left corner; they go stale when its windows move or resize. Read-only. Requires Screen Recording permission.",
        parameters: [
            .optional("app", type: .string, description: "\(ComputerUseTool.appDescription) Omit it to capture all displays."),
        ]
    ) { input in
        try checkScreenRecordingPermission()
        let app: NSRunningApplication? = if let name = input.app {
            try await ComputerUseTool.resolveApp(name)
        } else { nil }
        let image = try await ScreenControlManager.shared.screenshot(of: app)
        return try ScreenshotOutput(image, title: app?.localizedName ?? input.app ?? "the screen")
    }

    static let appZoom = Tool<AppZoomInput, ScreenshotOutput>(
        name: ToolNames.appZoom,
        description: "Take a sharper, magnified screenshot of a rectangle of the latest app_screenshot with the same `app`, at up to the display's native pixel density, to read small text or tell icons apart. The zoomed image is for viewing only: coordinates for app_click, app_scroll, and app_drag always refer to the app_screenshot, never to the zoomed image. Read-only. Requires Screen Recording permission.",
        parameters: [
            .optional("app", type: .string, description: "The application whose latest app_screenshot the rectangle is in. Omit it for a screenshot of all displays."),
            .required("x", type: .double, description: "Left edge of the rectangle, in pixels of the latest app_screenshot."),
            .required("y", type: .double, description: "Top edge of the rectangle, in pixels of the latest app_screenshot."),
            .required("width", type: .double, description: "Width of the rectangle, in pixels of the latest app_screenshot."),
            .required("height", type: .double, description: "Height of the rectangle, in pixels of the latest app_screenshot."),
        ]
    ) { input in
        try checkScreenRecordingPermission()
        let app: NSRunningApplication? = if let name = input.app {
            try await ComputerUseTool.resolveApp(name)
        } else { nil }
        guard let frame = ScreenControlManager.shared.screenshotFrames[app?.processIdentifier ?? 0] else {
            throw ComputerUseToolError.screenshotRequired
        }
        let rect = CGRect(
            x: frame.origin.x + input.x / frame.scale,
            y: frame.origin.y + input.y / frame.scale,
            width: input.width / frame.scale,
            height: input.height / frame.scale)
        let image = try await ScreenControlManager.shared.zoom(into: rect)
        return try ScreenshotOutput(image, title: "a zoomed region of \(app?.localizedName ?? input.app ?? "the screen")")
    }

    private static func checkScreenRecordingPermission() throws {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw ScreenControlToolError.screenRecordingPermissionNotGranted
        }
    }
}

enum ScreenControlToolError: LocalizedError {
    case screenRecordingPermissionNotGranted
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionNotGranted:
            "Screen Recording permission not granted. Enable ModelCraft in System Settings > Privacy & Security > Screen & System Audio Recording."
        case .encodingFailed:
            "The screenshot could not be encoded."
        }
    }
}

struct AppScreenshotInput: Codable {
    let app: String?
}

struct AppZoomInput: Codable {
    let app: String?
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct ScreenshotOutput: Codable {
    /// The JPEG saved in the chat's folder, like other media the tools produce.
    let imageURL: URL
    let mimeType: String
    let width: Int
    let height: Int
    /// What the image shows, such as an application's name.
    let title: String

    init(_ image: CGImage, title: String) throws {
        guard let data = image.data(type: .jpeg) else { throw ScreenControlToolError.encodingFailed }
        let type = UTType.jpeg
        imageURL = ProjectToolContext.chatDirectory.appendingPathComponent(UUID().uuidString, conformingTo: type)
        try data.write(to: imageURL)
        mimeType = type.preferredMIMEType!
        width = image.width
        height = image.height
        self.title = title
    }

    /// The model-facing text that accompanies the image.
    var summary: String {
        "Screenshot of \(title), \(width)x\(height) pixels."
    }
}
