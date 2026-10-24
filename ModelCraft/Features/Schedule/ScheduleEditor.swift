//
//  ScheduleEditor.swift
//  ModelCraft
//
//  Created by Hongshen on 24/10/26.
//

import SwiftUI
import SwiftData

struct ScheduleEditor: View {

    let schedule: Schedule?

    @State private var name: String
    @State private var prompt: String
    @State private var modelID: String
    @State private var project: Project?
    @State private var frequency: ScheduleRule.Frequency
    @State private var start: Date
    @State private var interval: Int
    @State private var weekdays: Set<Int>
    @State private var monthDays: Set<Int>
    @State private var months: Set<Int>
    @State private var workdays: ScheduleRule.WorkdayMode
    /// `nil` runs on the chosen weekdays or days of the month.
    @State private var workdayPosition: Int?
    @State private var hasEnd: Bool
    @State private var end: Date

    @Query(Project.fetch()) private var projects: [Project]
    @Query private var exceptions: [WorkdayException]

    @Environment(LocalModelStore.self) private var localModelStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private static let positions = [1, 2, 3, -1, -2]

    init(schedule: Schedule?, defaultModelID: String?) {
        self.schedule = schedule
        let calendar = Calendar.current
        let nextHour = calendar.nextDate(
            after: .now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? .now
        let rule = schedule?.rule ?? ScheduleRule(frequency: .daily, start: nextHour)
        _name = State(initialValue: schedule?.name ?? "")
        _prompt = State(initialValue: schedule?.prompt ?? "")
        _modelID = State(initialValue: schedule?.modelID ?? defaultModelID ?? "")
        _project = State(initialValue: schedule?.project)
        _frequency = State(initialValue: rule.frequency)
        _start = State(initialValue: rule.start)
        _interval = State(initialValue: rule.interval)
        _weekdays = State(initialValue: Set(rule.weekdays.isEmpty
            ? [calendar.component(.weekday, from: rule.start)] : rule.weekdays))
        _monthDays = State(initialValue: Set(rule.monthDays.isEmpty
            ? [calendar.component(.day, from: rule.start)] : rule.monthDays))
        _months = State(initialValue: Set(rule.months.isEmpty
            ? [calendar.component(.month, from: rule.start)] : rule.months))
        _workdays = State(initialValue: rule.workdays)
        _workdayPosition = State(initialValue: rule.workdayPosition)
        _hasEnd = State(initialValue: rule.end != nil)
        _end = State(initialValue: rule.end
            ?? calendar.date(byAdding: .month, value: 1, to: rule.start)!)
    }

    private var supportsPosition: Bool {
        [.weekly, .monthly, .yearly].contains(frequency)
    }

    private var usesPosition: Bool {
        supportsPosition && workdayPosition != nil
    }

    private var rule: Result<ScheduleRule, any Error> {
        Result {
            try ScheduleRule(
                frequency: frequency,
                start: start,
                interval: frequency == .once ? 1 : interval,
                weekdays: frequency == .weekly && !usesPosition ? weekdays.sorted() : [],
                monthDays: (frequency == .monthly || frequency == .yearly) && !usesPosition
                    ? monthDays.sorted() : [],
                months: frequency == .yearly ? months.sorted() : [],
                workdays: usesPosition ? .any : workdays,
                workdayPosition: usesPosition ? workdayPosition : nil,
                end: hasEnd && frequency != .once ? end : nil
            ).validated()
        }
    }

    private var canSave: Bool {
        guard case .success = rule else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelID.isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("Prompt", text: $prompt, prompt: Text("What should the assistant do each time?"), axis: .vertical)
                    .lineLimit(3...8)
                Picker("Model", selection: $modelID) {
                    if !localModelStore.contains(modelID) {
                        Text(modelID.isEmpty ? String(localized: "None") : modelID).tag(modelID)
                    }
                    ForEach(localModelStore.models) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                Picker("Project", selection: $project) {
                    Text("None").tag(Project?.none)
                    ForEach(projects) { project in
                        Text(project.title).tag(Optional(project))
                    }
                }
            } footer: {
                Text("Each run starts a new chat with this prompt. Nobody is present during a run, so questions go unanswered and actions that need approval are not performed.")
            }

            Section("Repeat") {
                Picker("Frequency", selection: $frequency) {
                    ForEach(ScheduleRule.Frequency.allCases) { frequency in
                        Text(frequency.title).tag(frequency)
                    }
                }
                DatePicker(selection: $start) {
                    frequency == .once ? Text("Time") : Text("Starts")
                }
                if frequency != .once {
                    Stepper(value: $interval, in: 1...1000) {
                        Text(intervalDescription)
                    }
                }
                if supportsPosition {
                    Picker("On", selection: $workdayPosition) {
                        (frequency == .weekly ? Text("Chosen weekdays") : Text("Chosen days"))
                            .tag(Int?.none)
                        ForEach(Self.positions, id: \.self) { position in
                            Text(ScheduleRule.positionDescription(position)).tag(Optional(position))
                        }
                    }
                }
                if frequency == .yearly {
                    LabeledContent("Months") {
                        DayGrid(values: Array(1...12), columns: 4, selection: $months) {
                            Calendar.current.shortMonthSymbols[$0 - 1]
                        }
                    }
                }
                if frequency == .weekly && !usesPosition {
                    LabeledContent("Weekdays") {
                        DayGrid(values: orderedWeekdays, columns: 7, selection: $weekdays) {
                            Calendar.current.veryShortWeekdaySymbols[$0 - 1]
                        }
                    }
                }
                if (frequency == .monthly || frequency == .yearly) && !usesPosition {
                    LabeledContent("Days") {
                        DayGrid(values: Array(1...31) + [-1], columns: 7, selection: $monthDays) {
                            $0 == -1 ? String(localized: "Last") : $0.formatted()
                        }
                    }
                }
                if !usesPosition {
                    Picker("Days Off", selection: $workdays) {
                        ForEach(availableWorkdayModes) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                }
                if frequency != .once {
                    Toggle("Ends", isOn: $hasEnd)
                    if hasEnd {
                        DatePicker("End", selection: $end)
                    }
                }
            }

            Section("Upcoming Runs") {
                switch rule {
                case .success(let rule):
                    let runs = rule.nextRuns(
                        after: .now,
                        count: 5,
                        in: HolidayStore.shared.workdayCalendar(exceptions: exceptions))
                    if runs.isEmpty {
                        Text("No upcoming runs")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(runs, id: \.self) { run in
                        Text(run.formatted(.dateTime.weekday(.wide).year().month().day().hour().minute()))
                    }
                case .failure(let error):
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 560)
        .onChange(of: frequency) {
            if !availableWorkdayModes.contains(workdays) {
                workdays = .only
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) {
                    schedule == nil ? Text("Create") : Text("Save")
                }
                .disabled(!canSave)
            }
        }
    }

    private var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private var availableWorkdayModes: [ScheduleRule.WorkdayMode] {
        frequency == .hourly ? [.any, .only] : ScheduleRule.WorkdayMode.allCases
    }

    private var intervalDescription: String {
        switch frequency {
        case .once: ""
        case .hourly: String(localized: "Every \(interval) hour(s)")
        case .daily: String(localized: "Every \(interval) day(s)")
        case .weekly: String(localized: "Every \(interval) week(s)")
        case .monthly: String(localized: "Every \(interval) month(s)")
        case .yearly: String(localized: "Every \(interval) year(s)")
        }
    }

    private func save() {
        guard case .success(let rule) = rule else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let schedule {
            schedule.name = name
            schedule.prompt = prompt
            schedule.modelID = modelID
            schedule.project = project
            schedule.rule = rule
            schedule.checkpoint = .now
        } else {
            modelContext.insert(Schedule(
                name: name, prompt: prompt, modelID: modelID, rule: rule, project: project))
        }
        try? modelContext.save()
        dismiss()
    }
}

/// A grid of toggles that edits a set of numbers.
private struct DayGrid: View {

    let values: [Int]
    let columns: Int
    @Binding var selection: Set<Int>
    let label: (Int) -> String

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
            ForEach(values, id: \.self) { value in
                Toggle(label(value), isOn: Binding {
                    selection.contains(value)
                } set: { isOn in
                    if isOn {
                        selection.insert(value)
                    } else if selection.count > 1 {
                        selection.remove(value)
                    }
                })
                .toggleStyle(.button)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

extension ScheduleRule.Frequency {
    var title: LocalizedStringResource {
        switch self {
        case .once: "Once"
        case .hourly: "Hourly"
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        }
    }
}

extension ScheduleRule.WorkdayMode {
    var title: LocalizedStringResource {
        switch self {
        case .any: "Run anyway"
        case .only: "Skip"
        case .next: "Move to the next workday"
        case .previous: "Move to the previous workday"
        }
    }
}
