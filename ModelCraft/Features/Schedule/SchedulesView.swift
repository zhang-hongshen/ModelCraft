//
//  SchedulesView.swift
//  ModelCraft
//
//  Created by Hongshen on 24/10/26.
//

import SwiftUI
import SwiftData

struct SchedulesView: View {

    @Query(sort: \Schedule.createdAt, order: .reverse) private var schedules: [Schedule]
    @Query private var exceptions: [WorkdayException]
    @State private var editorTarget: ScheduleEditorTarget?
    @State private var isWorkdaysPresented = false

    @Environment(\.modelContext) private var modelContext
    @Environment(GlobalStore.self) private var globalStore
    @Environment(Scheduler.self) private var scheduler

    var body: some View {
        let workdays = HolidayStore.shared.workdayCalendar(exceptions: exceptions)
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(schedules) { schedule in
                    ScheduleCard(
                        schedule: schedule,
                        nextRun: schedule.isEnabled
                            ? schedule.rule.nextRun(after: schedule.checkpoint, in: workdays)
                            : nil,
                        isRunning: scheduler.isRunning(schedule),
                        onEdit: { editorTarget = .edit(schedule) },
                        onRun: { scheduler.run(schedule) },
                        onStop: { Task { await scheduler.stop(schedule) } },
                        onDelete: { delete(schedule) })
                }
            }
            .padding()
        }
        .overlay {
            if schedules.isEmpty {
                ContentUnavailableView {
                    Label("No Scheduled Tasks", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Run a prompt automatically on a schedule, or ask the assistant to schedule one.")
                } actions: {
                    Button("New Scheduled Task") {
                        editorTarget = .new
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isWorkdaysPresented = true
                } label: {
                    Label("Workdays", systemImage: "calendar.badge.clock")
                }
                .help("Workdays")

                Button {
                    editorTarget = .new
                } label: {
                    Label("New Scheduled Task", systemImage: "plus")
                }
                .help("New Scheduled Task")
            }
        }
        .sheet(item: $editorTarget) { target in
            switch target {
            case .new:
                ScheduleEditor(schedule: nil, defaultModelID: globalStore.selectedModel?.id)
            case .edit(let schedule):
                ScheduleEditor(schedule: schedule, defaultModelID: globalStore.selectedModel?.id)
            }
        }
        .sheet(isPresented: $isWorkdaysPresented) {
            WorkdaysView()
        }
    }

    private func delete(_ schedule: Schedule) {
        Task {
            await scheduler.stop(schedule)
            modelContext.delete(schedule)
            try? modelContext.save()
        }
    }
}

enum ScheduleEditorTarget: Identifiable {
    case new
    case edit(Schedule)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let schedule): schedule.id.uuidString
        }
    }
}

private struct ScheduleCard: View {

    @Bindable var schedule: Schedule
    let nextRun: Date?
    let isRunning: Bool
    let onEdit: () -> Void
    let onRun: () -> Void
    let onStop: () -> Void
    let onDelete: () -> Void

    @State private var isRunsExpanded = false
    @Environment(GlobalStore.self) private var globalStore

    private var isEnabled: Binding<Bool> {
        Binding {
            schedule.isEnabled
        } set: { isEnabled in
            schedule.isEnabled = isEnabled
            // Runs that came due while the task was paused do not happen.
            schedule.checkpoint = .now
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(schedule.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(schedule.rule.localizedDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Button("Stop", action: onStop)
                } else {
                    Button("Run Now", action: onRun)
                }

                Toggle("Enabled", isOn: isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()

                Menu {
                    Button("Edit", action: onEdit)
                    DeleteButton(style: .textOnly, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
            }

            Text(schedule.prompt)
                .lineLimit(2)

            Label(nextRunDescription, systemImage: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let lastError = schedule.lastError {
                Label(lastError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if !schedule.chats.isEmpty {
                DisclosureGroup("Runs", isExpanded: $isRunsExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(schedule.sortedChats.prefix(10)) { chat in
                            Button(chat.createdAt.formatted(date: .abbreviated, time: .shortened)) {
                                globalStore.currentTab = .chat(chat)
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle().fill(.surface))
        .contextMenu {
            Button("Edit", action: onEdit)
            Button("Run Now", action: onRun)
                .disabled(isRunning)
            DeleteButton(style: .textOnly, action: onDelete)
        }
    }

    private var nextRunDescription: String {
        if !schedule.isEnabled {
            return String(localized: "Paused")
        }
        guard let nextRun else {
            return String(localized: "No upcoming runs")
        }
        return String(localized: "Next run \(nextRun.formatted(.dateTime.weekday(.wide).month().day().hour().minute()))")
    }
}

#if DEBUG
#Preview(traits: .preview) {
    SchedulesView()
}
#endif
