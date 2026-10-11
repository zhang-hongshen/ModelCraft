//
//  AppleScriptRunner.swift
//  ModelCraft
//

import AppKit
import ApplicationServices
import Foundation

/// Runs AppleScript for the native-application tools.
enum AppleScriptRunner {

    /// Launches the target application in the background when it is not running, runs the
    /// script, and returns its result. Callers are not on the main actor, so the script
    /// does not block the UI.
    static func run(_ source: String, in bundleIdentifier: String) async throws -> NSAppleEventDescriptor {
        try Task.checkCancellation()
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                throw AppleScriptError(message: "Application \(bundleIdentifier) is not installed.")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }

        guard let script = NSAppleScript(source: source) else {
            throw AppleScriptError(message: "The AppleScript source could not be created.")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw AppleScriptError(errorInfo)
        }
        return result
    }

    /// The items of a list result, in order.
    static func items(of descriptor: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard descriptor.numberOfItems > 0 else { return [] }
        return (1...descriptor.numberOfItems).compactMap { descriptor.atIndex($0) }
    }

    /// A result as text; lists are written as `[a, b]`.
    static func text(of descriptor: NSAppleEventDescriptor) -> String {
        switch descriptor.descriptorType {
        case typeAEList, typeAERecord:
            "[" + items(of: descriptor).map(text(of:)).joined(separator: ", ") + "]"
        case typeBoolean:
            descriptor.booleanValue ? "true" : "false"
        case typeNull:
            ""
        default:
            descriptor.stringValue ?? descriptor.description
        }
    }

    static func automationAuthorizationStatus(
        for bundleIdentifier: String
    ) -> AutomationAuthorizationStatus {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty,
              let address = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier).aeDesc
        else {
            return .applicationNotRunning
        }
        switch Int(AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, false)) {
        case Int(noErr):
            return .allowed
        case Int(errAEEventNotPermitted), Int(errAETargetAddressNotPermitted):
            return .denied
        case Int(errAEEventWouldRequireUserConsent):
            return .notDetermined
        case Int(procNotFound):
            return .applicationNotRunning
        default:
            return .unknown
        }
    }
}

enum AutomationAuthorizationStatus {
    case allowed
    case denied
    case notDetermined
    case applicationNotRunning
    case unknown
}

struct AppleScriptError: LocalizedError {

    let message: String

    var errorDescription: String? { message }

    init(message: String) {
        self.message = message
    }

    init(_ info: NSDictionary) {
        let number = info[NSAppleScript.errorNumber] as? Int
        if number == Int(errAEEventNotPermitted) || number == Int(errAETargetAddressNotPermitted) {
            message = "Automation permission was denied. Enable ModelCraft for the target application in System Settings > Privacy & Security > Automation, then try again."
        } else {
            message = "AppleScript failed: \(info[NSAppleScript.errorMessage] as? String ?? "unknown error")"
        }
    }
}

/// Builds AppleScript literals from tool arguments. Model or user strings must go through
/// these instead of being interpolated into script source.
enum AppleScriptLiteral {

    static func string(_ value: String) -> String {
        var parts: [String] = []
        var current = ""

        func flush() {
            guard !current.isEmpty else { return }
            parts.append("\"\(current)\"")
            current = ""
        }

        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22:
                current.append("\\\"")
            case 0x5C:
                current.append("\\\\")
            case 0x0A:
                flush()
                parts.append("linefeed")
            case 0x0D:
                flush()
                parts.append("return")
            case 0x09:
                flush()
                parts.append("tab")
            case 0x00...0x1F, 0x7F:
                flush()
                parts.append("character id \(scalar.value)")
            default:
                current.unicodeScalars.append(scalar)
            }
        }
        flush()
        return parts.isEmpty ? "\"\"" : parts.joined(separator: " & ")
    }

    static func stringList(_ values: [String]) -> String {
        "{\(values.map(string).joined(separator: ", "))}"
    }
}
