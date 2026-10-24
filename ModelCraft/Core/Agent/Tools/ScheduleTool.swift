//
//  ScheduleTool.swift
//  ModelCraft
//
//  Created by Hongshen on 24/10/26.
//

import Foundation
import SwiftData

import MLXLMCommon

enum ScheduleTool {

    static var allTools: [any ToolProtocol] {
        [
            createSchedule(projectID: nil, modelID: nil),
            listSchedules, updateSchedule, deleteSchedule,
            listWorkdays, setWorkday,
        ]
    }

    private static let workdayDefinition = "A workday is a day outside the locale's weekend, adjusted for the public holidays and makeup workdays of the holiday region the user chose and for the user's own exceptions; workdays_list shows them."

    private static var ruleParameters: [ToolParameter] {
        [
            .optional("interval", type: .int, description: "Run every this many hours, days, weeks, months, or years, as the frequency gives. Defaults to 1."),
            .optional("weekdays", type: .array(elementType: .string), description: "Weekly only: the days of the week to run on, as lowercase English names such as `monday`. Defaults to the weekday of start_at. Do not combine with workday_position."),
            .optional("month_days", type: .array(elementType: .int), description: "Monthly or yearly only: the days of the month to run on, from 1 through 31, or -1 for the last day. A day a month does not have is skipped. Defaults to the day of start_at. Do not combine with workday_position."),
            .optional("months", type: .array(elementType: .int), description: "Yearly only: the months to run in, from 1 through 12. Defaults to the month of start_at."),
            .optional("workdays", type: .string, description: "How runs treat days that are not workdays: `any` runs on them (the default), `only` skips them, `next` moves the run to the next workday, and `previous` moves it to the previous workday. Hourly schedules accept only `any` and `only`.", extraProperties: ["enum": ["any", "only", "next", "previous"]]),
            .optional("workday_position", type: .int, description: "Weekly, monthly, or yearly only: run on this workday of each week, each month, or each listed month instead of on fixed days. 1 is the first workday, 2 the second, -1 the last, and -2 the second to last. For example, monthly with -1 runs on the last workday of every month."),
            .optional("end_at", type: .string, description: "ISO 8601 date and time after which no run happens. Omit for no end."),
        ]
    }

    static func createSchedule(
        projectID: PersistentIdentifier?,
        modelID: String?
    ) -> Tool<CreateScheduleInput, ScheduleOutput> {
        Tool<CreateScheduleInput, ScheduleOutput>(
            name: ToolNames.createSchedule,
            description:
            """
                Create a scheduled task: a prompt that ModelCraft sends automatically as a new chat, with the current chat's model and in the current chat's project, at the times a recurrence rule gives (once, hourly, daily, weekly, monthly, or yearly, optionally limited to or moved onto workdays). Use it for recurring or future work such as a morning briefing every workday or a report on the last workday of each month. Requires confirmation.
                Runs happen only while ModelCraft is open; runs missed while it was closed happen once when it opens. During a run nobody is present, so questions go unanswered and actions that need confirmation are refused; write the prompt so it can be completed without them.
                \(workdayDefinition)
                Returns the schedule_id, a description of the rule, and the next run times; check them against the request.
            """,
            parameters: [
                .required("name", type: .string, description: "A short name for the task, used as the title of each run's chat."),
                .required("prompt", type: .string, description: "The complete, self-contained request sent at each run, written as the user would ask it. It must not depend on this conversation, which the run cannot see."),
                .required("frequency", type: .string, description: "How often the task repeats.", extraProperties: ["enum": ScheduleRule.Frequency.allCases.map(\.rawValue)]),
                .required("start_at", type: .string, description: "ISO 8601 date and time of the first possible run, in the user's time zone when it has no offset. Its time of day is the run time of daily and longer schedules; hourly runs step from it. A `once` schedule runs exactly then."),
            ] + ruleParameters
        ) { input in
            try await MainActor.run {
                let context = ModelContainer.shared.mainContext
                guard let modelID else { throw ScheduleToolError.modelUnavailable }
                let rule = try ScheduleTool.rule(
                    frequency: input.frequency, startAt: input.startAt, fields: input.rule)
                let project = projectID.flatMap { context.model(for: $0) as? Project }
                let schedule = Schedule(
                    name: input.name,
                    prompt: input.prompt,
                    modelID: modelID,
                    rule: rule,
                    project: project)
                context.persist(schedule)
                return output(schedule)
            }
        }
    }

    static let listSchedules = Tool<ListSchedulesInput, [ScheduleOutput]>(
        name: ToolNames.listSchedules,
        description: "List the user's scheduled tasks with their schedule_id, prompt, rule, whether they are enabled, the next run times, and the latest run's time and error. This is read-only; use it to find the schedule_id that schedule_update and schedule_delete need.",
        parameters: []
    ) { _ in
        try await MainActor.run {
            try ModelContainer.shared.mainContext
                .fetch(FetchDescriptor<Schedule>(sortBy: [.init(\.createdAt)]))
                .map(output)
        }
    }

    static let updateSchedule = Tool<UpdateScheduleInput, ScheduleOutput>(
        name: ToolNames.updateSchedule,
        description:
        """
            Change a scheduled task by the schedule_id from schedule_list or schedule_create: rename it, replace its prompt, pause or resume it, or replace its rule. Requires confirmation. Omit fields that stay unchanged. Giving any rule field replaces the whole rule, so frequency and start_at are then required and omitted rule fields take their defaults. Runs due before the change do not happen.
            \(workdayDefinition)
            Returns the updated task with its next run times.
        """,
        parameters: [
            .required("schedule_id", type: .string, description: "The schedule_id of the task to change."),
            .optional("name", type: .string, description: "Replacement name."),
            .optional("prompt", type: .string, description: "Replacement self-contained request sent at each run."),
            .optional("enabled", type: .bool, description: "`false` pauses the task and `true` resumes it."),
            .optional("frequency", type: .string, description: "How often the task repeats, when the rule is replaced.", extraProperties: ["enum": ScheduleRule.Frequency.allCases.map(\.rawValue)]),
            .optional("start_at", type: .string, description: "ISO 8601 date and time of the first possible run, when the rule is replaced. Its time of day is the run time of daily and longer schedules."),
        ] + ruleParameters
    ) { input in
        try await MainActor.run {
            let schedule = try ScheduleTool.schedule(id: input.scheduleID)
            if let name = input.name { schedule.name = name }
            if let prompt = input.prompt { schedule.prompt = prompt }
            if let enabled = input.enabled { schedule.isEnabled = enabled }
            if input.frequency != nil || input.startAt != nil || input.rule.isSpecified {
                guard let frequency = input.frequency, let startAt = input.startAt else {
                    throw ScheduleToolError.incompleteRule
                }
                schedule.rule = try ScheduleTool.rule(frequency: frequency, startAt: startAt, fields: input.rule)
            }
            schedule.checkpoint = .now
            try ModelContainer.shared.mainContext.save()
            return output(schedule)
        }
    }

    static let deleteSchedule = Tool<DeleteScheduleInput, DeleteScheduleOutput>(
        name: ToolNames.deleteSchedule,
        description: "Delete a scheduled task by the schedule_id from schedule_list, so it never runs again. Chats from earlier runs are kept. Requires confirmation. To stop it only for a while, use schedule_update with enabled set to false instead.",
        parameters: [
            .required("schedule_id", type: .string, description: "The schedule_id of the task to delete."),
        ]
    ) { input in
        try await MainActor.run {
            let schedule = try ScheduleTool.schedule(id: input.scheduleID)
            let name = schedule.name
            ModelContainer.shared.mainContext.delete(schedule)
            try ModelContainer.shared.mainContext.save()
            return DeleteScheduleOutput(deleted: name)
        }
    }

    static let listWorkdays = Tool<ListWorkdaysInput, ListWorkdaysOutput>(
        name: ToolNames.listWorkdays,
        description: "List each day in a date range with whether it is a workday for scheduled tasks and why: weekday, weekend, public holiday, makeup workday, or the user's exception. This is read-only. Use it to answer whether a date is a workday or to check when a workday schedule will run.",
        parameters: [
            .optional("start_date", type: .string, description: "The first day as `yyyy-MM-dd`. Defaults to today."),
            .optional("days", type: .int, description: "How many days to list, from 1 through 366. Defaults to 14."),
        ]
    ) { input in
        try await MainActor.run {
            let calendar = Calendar.current
            let start = try input.startDate.map(day(from:)) ?? calendar.startOfDay(for: .now)
            let count = min(max(input.days ?? 14, 1), 366)
            let workdays = HolidayStore.shared.workdayCalendar()
            let days = (0..<count).map { offset in
                dayOutput(workdays.day(calendar.date(byAdding: .day, value: offset, to: start)!))
            }
            let store = HolidayStore.shared
            let years = Set(days.compactMap { Int($0.date.prefix(4)) })
            return ListWorkdaysOutput(
                holidayRegion: store.region.isEmpty ? nil : store.region,
                yearsWithoutHolidayData: store.region.isEmpty
                    ? [] : years.subtracting(store.loadedYears).sorted(),
                days: days)
        }
    }

    static let setWorkday = Tool<SetWorkdayInput, WorkdayOutput>(
        name: ToolNames.setWorkday,
        description: "Set whether one day is a workday for scheduled tasks, overriding the weekend and public holidays, such as a company day off or a weekend the user works; or remove that override. Requires confirmation. Workday schedules follow the change from their next run. Returns the day as it now counts.",
        parameters: [
            .required("date", type: .string, description: "The day as `yyyy-MM-dd`."),
            .required("kind", type: .string, description: "`workday` makes the day a workday, `day_off` makes it a day off, and `default` removes the override so the weekend and public holidays decide again.", extraProperties: ["enum": ["workday", "day_off", "default"]]),
            .optional("name", type: .string, description: "Why the day differs, such as `Company offsite`."),
        ]
    ) { input in
        try await MainActor.run {
            let date = try day(from: input.date)
            let key = WorkdayCalendar.key(for: date)
            let context = ModelContainer.shared.mainContext
            let existing = try context.fetch(FetchDescriptor<WorkdayException>(
                predicate: #Predicate<WorkdayException> { $0.day == key }))
            context.delete(existing)
            switch input.kind {
            case "workday", "day_off":
                context.insert(WorkdayException(
                    day: key, isWorkday: input.kind == "workday", name: input.name ?? ""))
            case "default":
                break
            default:
                throw ScheduleToolError.invalidKind(input.kind)
            }
            try context.save()
            return dayOutput(HolidayStore.shared.workdayCalendar().day(date))
        }
    }
}

// MARK: - Helpers

extension ScheduleTool {

    @MainActor
    private static func rule(
        frequency: String,
        startAt: String,
        fields: ScheduleRuleFields
    ) throws -> ScheduleRule {
        guard let frequency = ScheduleRule.Frequency(rawValue: frequency) else {
            throw ScheduleToolError.invalidFrequency(frequency)
        }
        let symbols = englishWeekdays.map { $0.lowercased() }
        let weekdays = try (fields.weekdays ?? []).map { name in
            guard let index = symbols.firstIndex(of: name.lowercased()) else {
                throw ScheduleToolError.invalidWeekday(name)
            }
            return index + 1
        }
        let workdays = try fields.workdays.map { value in
            guard let mode = ScheduleRule.WorkdayMode(rawValue: value) else {
                throw ScheduleToolError.invalidWorkdays(value)
            }
            return mode
        } ?? .any
        return try ScheduleRule(
            frequency: frequency,
            start: date(from: startAt),
            interval: fields.interval ?? 1,
            weekdays: weekdays,
            monthDays: fields.monthDays ?? [],
            months: fields.months ?? [],
            workdays: workdays,
            workdayPosition: fields.workdayPosition,
            end: fields.endAt.map(date(from:))
        ).validated()
    }

    @MainActor
    private static func schedule(id: String) throws -> Schedule {
        guard let uuid = UUID(uuidString: id),
              let schedule = try ModelContainer.shared.mainContext.fetch(FetchDescriptor<Schedule>(
                predicate: #Predicate<Schedule> { $0.id == uuid })).first
        else {
            throw ScheduleToolError.scheduleNotFound(id)
        }
        return schedule
    }

    @MainActor
    private static func output(_ schedule: Schedule) -> ScheduleOutput {
        let workdays = HolidayStore.shared.workdayCalendar()
        let nextRuns = schedule.isEnabled
            ? schedule.rule.nextRuns(after: max(schedule.checkpoint, .now), count: 5, in: workdays)
            : []
        return ScheduleOutput(
            scheduleID: schedule.id.uuidString,
            name: schedule.name,
            prompt: schedule.prompt,
            schedule: schedule.rule.localizedDescription,
            enabled: schedule.isEnabled,
            nextRuns: nextRuns.map(timestamp),
            project: schedule.project?.title,
            model: schedule.modelID,
            lastRunAt: schedule.lastRunAt.map(timestamp),
            lastError: schedule.lastError)
    }

    private static func dayOutput(_ day: WorkdayCalendar.Day) -> WorkdayOutput {
        let reason = switch day.reason {
        case .weekday: "weekday"
        case .weekend: "weekend"
        case .holiday(let name): "public holiday: \(name)"
        case .makeupWorkday(let name): "makeup workday: \(name)"
        case .exception(let name): name.isEmpty ? "user exception" : "user exception: \(name)"
        }
        return WorkdayOutput(
            date: WorkdayCalendar.key(for: day.date),
            weekday: weekdayName(day.date),
            workday: day.isWorkday,
            reason: reason)
    }

    /// An ISO 8601 time with the weekday, which models cannot reliably derive themselves.
    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return "\(formatter.string(from: date)) \(weekdayName(date))"
    }

    private static func weekdayName(_ date: Date) -> String {
        englishWeekdays[Calendar.current.component(.weekday, from: date) - 1]
    }

    /// Weekday names in the tool contract, Sunday first, whatever the user's language.
    private static var englishWeekdays: [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar.weekdaySymbols
    }

    /// Accepts an ISO 8601 time with an offset, or a local time without one.
    private static func date(from value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let date = local.date(from: value) { return date }
        }
        throw ScheduleToolError.invalidDate(value)
    }

    private static func day(from value: String) throws -> Date {
        guard let date = WorkdayCalendar.date(forKey: value) else {
            throw ScheduleToolError.invalidDate(value)
        }
        return date
    }
}

enum ScheduleToolError: LocalizedError {
    case modelUnavailable
    case incompleteRule
    case invalidFrequency(String)
    case invalidWeekday(String)
    case invalidWorkdays(String)
    case invalidKind(String)
    case invalidDate(String)
    case scheduleNotFound(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            "No model is selected for the scheduled task."
        case .incompleteRule:
            "Replacing the rule requires both frequency and start_at."
        case .invalidFrequency(let value):
            "Unknown frequency `\(value)`. Use once, hourly, daily, weekly, monthly, or yearly."
        case .invalidWeekday(let value):
            "Unknown weekday `\(value)`. Use lowercase English names such as monday."
        case .invalidWorkdays(let value):
            "Unknown workdays value `\(value)`. Use any, only, next, or previous."
        case .invalidKind(let value):
            "Unknown kind `\(value)`. Use workday, day_off, or default."
        case .invalidDate(let value):
            "`\(value)` is not a valid date. Use ISO 8601, such as 2026-10-26T09:00:00+08:00, or yyyy-MM-dd for a day."
        case .scheduleNotFound(let id):
            "No scheduled task has the schedule_id \(id). Call schedule_list for the current identifiers."
        }
    }
}

/// The rule fields shared by creating and updating a schedule.
struct ScheduleRuleFields: Codable {
    let interval: Int?
    let weekdays: [String]?
    let monthDays: [Int]?
    let months: [Int]?
    let workdays: String?
    let workdayPosition: Int?
    let endAt: String?

    var isSpecified: Bool {
        interval != nil || weekdays != nil || monthDays != nil || months != nil
            || workdays != nil || workdayPosition != nil || endAt != nil
    }

    enum CodingKeys: String, CodingKey {
        case interval, weekdays, months, workdays
        case monthDays = "month_days"
        case workdayPosition = "workday_position"
        case endAt = "end_at"
    }
}

struct CreateScheduleInput: Codable {
    let name: String
    let prompt: String
    let frequency: String
    let startAt: String
    let rule: ScheduleRuleFields

    enum CodingKeys: String, CodingKey {
        case name, prompt, frequency
        case startAt = "start_at"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        prompt = try container.decode(String.self, forKey: .prompt)
        frequency = try container.decode(String.self, forKey: .frequency)
        startAt = try container.decode(String.self, forKey: .startAt)
        rule = try ScheduleRuleFields(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(frequency, forKey: .frequency)
        try container.encode(startAt, forKey: .startAt)
        try rule.encode(to: encoder)
    }
}

struct UpdateScheduleInput: Codable {
    let scheduleID: String
    let name: String?
    let prompt: String?
    let enabled: Bool?
    let frequency: String?
    let startAt: String?
    let rule: ScheduleRuleFields

    enum CodingKeys: String, CodingKey {
        case name, prompt, enabled, frequency
        case scheduleID = "schedule_id"
        case startAt = "start_at"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scheduleID = try container.decode(String.self, forKey: .scheduleID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        frequency = try container.decodeIfPresent(String.self, forKey: .frequency)
        startAt = try container.decodeIfPresent(String.self, forKey: .startAt)
        rule = try ScheduleRuleFields(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scheduleID, forKey: .scheduleID)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(prompt, forKey: .prompt)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encodeIfPresent(frequency, forKey: .frequency)
        try container.encodeIfPresent(startAt, forKey: .startAt)
        try rule.encode(to: encoder)
    }
}

struct ListSchedulesInput: Codable {}

struct DeleteScheduleInput: Codable {
    let scheduleID: String

    enum CodingKeys: String, CodingKey {
        case scheduleID = "schedule_id"
    }
}

struct DeleteScheduleOutput: Codable {
    let deleted: String
}

struct ScheduleOutput: Codable {
    let scheduleID: String
    let name: String
    let prompt: String
    let schedule: String
    let enabled: Bool
    let nextRuns: [String]
    let project: String?
    let model: String
    let lastRunAt: String?
    let lastError: String?

    enum CodingKeys: String, CodingKey {
        case name, prompt, schedule, enabled, project, model
        case scheduleID = "schedule_id"
        case nextRuns = "next_runs"
        case lastRunAt = "last_run_at"
        case lastError = "last_error"
    }
}

struct ListWorkdaysInput: Codable {
    let startDate: String?
    let days: Int?

    enum CodingKeys: String, CodingKey {
        case days
        case startDate = "start_date"
    }
}

struct ListWorkdaysOutput: Codable {
    /// `nil` when no region is chosen, so only the weekend and exceptions count.
    let holidayRegion: String?
    /// Years in the range whose public holidays are not known, so only the weekend counts.
    let yearsWithoutHolidayData: [Int]
    let days: [WorkdayOutput]

    enum CodingKeys: String, CodingKey {
        case days
        case holidayRegion = "holiday_region"
        case yearsWithoutHolidayData = "years_without_holiday_data"
    }
}

struct SetWorkdayInput: Codable {
    let date: String
    let kind: String
    let name: String?
}

struct WorkdayOutput: Codable {
    let date: String
    let weekday: String
    let workday: Bool
    let reason: String
}
