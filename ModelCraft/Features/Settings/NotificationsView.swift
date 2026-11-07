//
//  NotificationsView.swift
//  ModelCraft
//

import SwiftUI
import UserNotifications

struct NotificationsView: View {
    @Environment(UserSettings.self) private var userSettings
    @Environment(\.openURL) private var openURL
    @State private var areNotificationsDenied = false

    private static let notificationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

    var body: some View {
        @Bindable var userSettings = userSettings

        Form {
            Section {
                Toggle("Notify when scheduled tasks finish", isOn: $userSettings.notifyWhenScheduledTasksFinish)
                if userSettings.notifyWhenScheduledTasksFinish && areNotificationsDenied {
                    LabeledContent {
                        Button("Open System Settings") {
                            openURL(Self.notificationSettingsURL)
                        }
                    } label: {
                        Label("Notifications for ModelCraft are turned off in System Settings.", systemImage: "exclamationmark.triangle")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: userSettings.notifyWhenScheduledTasksFinish) {
            guard userSettings.notifyWhenScheduledTasksFinish else { return }
            // Turning the setting on is when macOS asks for permission the first time.
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])) ?? false
            areNotificationsDenied = !granted
        }
    }
}

#Preview {
    NotificationsView().environment(UserSettings())
}
