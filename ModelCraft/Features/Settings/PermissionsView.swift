//
//  PermissionsView.swift
//  ModelCraft
//

import AppKit
import ApplicationServices
import CoreGraphics
import EventKit
import SwiftUI

struct PermissionsView: View {

    @State private var calendarState: PermissionState = .notDetermined
    @State private var remindersState: PermissionState = .notDetermined
    @State private var notesState: PermissionState = .applicationNotRunning
    @State private var mailState: PermissionState = .applicationNotRunning
    @State private var accessibilityState: PermissionState = .notDetermined
    @State private var screenRecordingState: PermissionState = .notDetermined

    var body: some View {
        Form {
            Section("Native Application Data") {
                PermissionRow(
                    title: "Calendars",
                    state: calendarState,
                    actionTitle: eventKitActionTitle(for: calendarState)) {
                        handleEventKitAction(
                            for: calendarState,
                            entityType: .event,
                            settingsPane: "Privacy_Calendars")
                    }
                PermissionRow(
                    title: "Reminders",
                    state: remindersState,
                    actionTitle: eventKitActionTitle(for: remindersState)) {
                        handleEventKitAction(
                            for: remindersState,
                            entityType: .reminder,
                            settingsPane: "Privacy_Reminders")
                    }
            }

            Section("Automation") {
                PermissionRow(
                    title: "Notes",
                    state: notesState,
                    actionTitle: "Open Settings") {
                        openPrivacySettings("Privacy_Automation")
                    }
                PermissionRow(
                    title: "Mail",
                    state: mailState,
                    actionTitle: "Open Settings") {
                        openPrivacySettings("Privacy_Automation")
                    }
            }

            Section("GUI Fallback") {
                PermissionRow(
                    title: "Accessibility",
                    state: accessibilityState,
                    actionTitle: "Open Settings") {
                        openPrivacySettings("Privacy_Accessibility")
                    }
                PermissionRow(
                    title: "Screen Recording",
                    state: screenRecordingState,
                    actionTitle: "Open Settings") {
                        openPrivacySettings("Privacy_ScreenCapture")
                    }
            }
        }
        .formStyle(.grouped)
        .task {
            refresh()
        }
    }

    private func requestEventKitAccess(to entityType: EKEntityType) {
        Task {
            try? await NativeEventStore.shared.requestAccess(to: entityType)
            refresh()
        }
    }

    private func eventKitActionTitle(
        for state: PermissionState
    ) -> LocalizedStringResource? {
        switch state {
        case .allowed:
            nil
        case .denied:
            "Open Settings"
        default:
            "Request Access"
        }
    }

    private func handleEventKitAction(
        for state: PermissionState,
        entityType: EKEntityType,
        settingsPane: String
    ) {
        if state == .denied {
            openPrivacySettings(settingsPane)
        } else {
            requestEventKitAccess(to: entityType)
        }
    }

    private func refresh() {
        calendarState = PermissionState(
            EKEventStore.authorizationStatus(for: .event))
        remindersState = PermissionState(
            EKEventStore.authorizationStatus(for: .reminder))
        notesState = PermissionState(
            AppleScriptRunner.automationAuthorizationStatus(
                for: NativeApplication.notes.bundleIdentifier))
        mailState = PermissionState(
            AppleScriptRunner.automationAuthorizationStatus(
                for: NativeApplication.mail.bundleIdentifier))
        accessibilityState = AXIsProcessTrusted() ? .allowed : .denied
        screenRecordingState = CGPreflightScreenCaptureAccess()
            ? .allowed
            : .denied
    }

    private func openPrivacySettings(_ pane: String) {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct PermissionRow: View {
    let title: LocalizedStringResource
    let state: PermissionState
    let actionTitle: LocalizedStringResource?
    let action: () -> Void

    var body: some View {
        LabeledContent {
            HStack {
                Label {
                    Text(state.title)
                } icon: {
                    Image(systemName: state.icon)
                }
                    .foregroundStyle(state.color)
                if let actionTitle {
                    Button(action: action) {
                        Text(actionTitle)
                    }
                }
            }
        } label: {
            Text(title)
        }
    }
}

private enum PermissionState: Equatable {
    case allowed
    case limited
    case denied
    case notDetermined
    case applicationNotRunning
    case unknown

    init(_ status: EKAuthorizationStatus) {
        switch status {
        case .fullAccess:
            self = .allowed
        case .writeOnly:
            self = .limited
        case .denied, .restricted:
            self = .denied
        case .notDetermined:
            self = .notDetermined
        @unknown default:
            self = .unknown
        }
    }

    init(_ status: AutomationAuthorizationStatus) {
        switch status {
        case .allowed: self = .allowed
        case .denied: self = .denied
        case .notDetermined: self = .notDetermined
        case .applicationNotRunning: self = .applicationNotRunning
        case .unknown: self = .unknown
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .allowed: "Allowed"
        case .limited: "Limited Access"
        case .denied: "Not Allowed"
        case .notDetermined: "Not Requested"
        case .applicationNotRunning: "Checked When App Runs"
        case .unknown: "Unknown"
        }
    }

    var icon: String {
        switch self {
        case .allowed: "checkmark.circle.fill"
        case .limited: "exclamationmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .notDetermined, .applicationNotRunning, .unknown: "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .allowed: .green
        case .limited: .orange
        case .denied: .red
        case .notDetermined, .applicationNotRunning, .unknown: .secondary
        }
    }
}
