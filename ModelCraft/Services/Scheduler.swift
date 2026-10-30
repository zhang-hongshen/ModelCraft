//
//  Scheduler.swift
//  ModelCraft
//
//  Created by Hongshen on 24/10/26.
//

import AppKit
import SwiftData
import UserNotifications

/// Runs due schedules while the app is open. Each run is a new chat that sends the schedule's
/// prompt with nobody present to answer questions or approve actions.
@MainActor
@Observable
final class Scheduler {

    private struct Run {
        let task: Task<Void, Never>
        let service: ChatService
        let chat: Chat
    }

    private var runs: [UUID: Run] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private let notificationDelegate = NotificationDelegate()
    private let localModelStore: LocalModelStore
    private let globalStore: GlobalStore

    /// The longest wait between checks, so new and edited schedules are picked up.
    private static let checkInterval: TimeInterval = 30
    /// The longest reply excerpt shown in a run's notification.
    private static let notificationBodyLength = 200

    init(localModelStore: LocalModelStore, globalStore: GlobalStore) {
        self.localModelStore = localModelStore
        self.globalStore = globalStore
        notificationDelegate.onOpen = { [weak self] chatID in
            self?.openChat(id: chatID)
        }
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    func isRunning(_ schedule: Schedule) -> Bool {
        runs[schedule.id] != nil
    }

    func start() {
        guard loop == nil else { return }
        loop = Task {
            var holidaysRefreshedAt = Date.distantPast
            while !Task.isCancelled {
                if Date.now.timeIntervalSince(holidaysRefreshedAt) > 24 * 3600 {
                    holidaysRefreshedAt = .now
                    await HolidayStore.shared.refresh()
                }
                let wait = runDueSchedules()
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// Starts a run of `schedule` now, unless one is still going.
    func run(_ schedule: Schedule) {
        schedule.checkpoint = .now
        guard runs[schedule.id] == nil else { return }
        schedule.lastRunAt = .now
        guard let model = localModelStore.models.first(where: { $0.id == schedule.modelID }) else {
            schedule.lastError = String(localized: "The model \(schedule.modelID) is not downloaded.")
            return
        }
        let service = ChatService(isUnattended: true)
        let chat = service.createChat(project: schedule.project)
        chat.title = schedule.name
        chat.schedule = schedule
        let message = Message(role: .user, chat: chat, content: schedule.prompt)
        let scheduleID = schedule.id
        let task = Task {
            defer { runs[scheduleID] = nil }
            do {
                try await service.sendMessage(model: model, chat: chat, message: message)
                schedule.lastError = nil
                let reply = chat.conversation.last { $0.role == .assistant && !$0.content.isEmpty }
                notify(chat: chat, title: schedule.name, body: reply.map {
                    String($0.content.trimmingCharacters(in: .whitespacesAndNewlines)
                        .prefix(Self.notificationBodyLength))
                } ?? String(localized: "The run finished."))
            } catch is CancellationError {
                schedule.lastError = nil
            } catch {
                schedule.lastError = error.localizedDescription
                notify(
                    chat: chat,
                    title: String(localized: "\(schedule.name) failed"),
                    body: error.localizedDescription)
            }
        }
        runs[scheduleID] = Run(task: task, service: service, chat: chat)
    }

    /// Posts a notification for a finished run when the user turned them on in Settings. A
    /// stopped run is not announced.
    private func notify(chat: Chat, title: String, body: String) {
        guard UserDefaults.standard.value(
            forKey: UserDefaults.notifyWhenScheduledTasksFinish,
            default: UserDefaultSettings.notifyWhenScheduledTasksFinish)
        else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [NotificationDelegate.chatIDKey: chat.id.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: chat.id.uuidString, content: content, trigger: nil))
    }

    private func openChat(id: UUID) {
        guard let chat = try? ModelContainer.shared.mainContext.fetch(FetchDescriptor<Chat>(
            predicate: #Predicate<Chat> { $0.id == id })).first
        else { return }
        globalStore.currentTab = .chat(chat)
        NSApp.activate()
    }

    func stop(_ schedule: Schedule) async {
        guard let run = runs[schedule.id] else { return }
        await run.service.stopGenerating(chat: run.chat)
        run.task.cancel()
    }

    /// Starts every enabled schedule whose next run is due and returns the seconds until the
    /// next check.
    private func runDueSchedules() -> TimeInterval {
        let schedules = (try? ModelContainer.shared.mainContext.fetch(
            FetchDescriptor<Schedule>(predicate: #Predicate<Schedule> { $0.isEnabled }))) ?? []
        keepAppAwake(!schedules.isEmpty)
        let workdays = HolidayStore.shared.workdayCalendar()
        let now = Date.now
        var wait = Self.checkInterval
        for schedule in schedules {
            guard let next = schedule.rule.nextRun(after: schedule.checkpoint, in: workdays) else {
                continue
            }
            if next <= now {
                run(schedule)
            } else {
                wait = min(wait, next.timeIntervalSince(now))
            }
        }
        return max(wait, 1)
    }

    /// App Nap delays timers while the window is hidden, so the app opts out of it while any
    /// schedule is enabled. Idle system sleep still happens.
    private func keepAppAwake(_ isNeeded: Bool) {
        if isNeeded, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Running scheduled tasks")
        } else if !isNeeded, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}

/// Shows run notifications while the app is in front and opens a run's chat when one is
/// clicked.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    static let chatIDKey = "chatID"

    var onOpen: (@MainActor (UUID) -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let value = response.notification.request.content.userInfo[Self.chatIDKey] as? String,
              let chatID = UUID(uuidString: value)
        else { return }
        await onOpen?(chatID)
    }
}
