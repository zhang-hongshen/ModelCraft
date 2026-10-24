//
//  Schedule.swift
//  ModelCraft
//
//  Created by Hongshen on 24/10/26.
//

import Foundation
import SwiftData

/// A prompt the scheduler sends as a new chat at the times its rule gives.
@Model
class Schedule {
    @Attribute(.unique) var id = UUID()
    var createdAt: Date = Date.now
    var name: String
    /// The request sent as the user message of each run.
    var prompt: String
    var modelID: String
    private var ruleData: Data
    var isEnabled: Bool = true
    /// Runs are due only after this moment. It moves to the time of each run and each edit,
    /// so occurrences missed while the app was closed collapse into one run, and an edit
    /// never fires occurrences from before it.
    var checkpoint: Date = Date.now
    var lastRunAt: Date?
    /// Why the latest run failed, or `nil` when it succeeded.
    var lastError: String?
    var project: Project?

    @Relationship(deleteRule: .nullify, inverse: \Chat.schedule)
    var chats: [Chat] = []

    /// Stored encoded, as SwiftData's composite attributes do not reliably hold enums.
    @Transient var rule: ScheduleRule {
        get {
            (try? JSONDecoder().decode(ScheduleRule.self, from: ruleData))
                ?? ScheduleRule(frequency: .once, start: createdAt)
        }
        set {
            ruleData = (try? JSONEncoder().encode(newValue)) ?? ruleData
        }
    }

    init(name: String, prompt: String, modelID: String, rule: ScheduleRule, project: Project? = nil) {
        self.name = name
        self.prompt = prompt
        self.modelID = modelID
        self.ruleData = (try? JSONEncoder().encode(rule)) ?? Data()
        self.project = project
    }
}

extension Schedule {

    var sortedChats: [Chat] {
        chats.sorted { $0.createdAt > $1.createdAt }
    }
}

/// A day whose workday status the user set, overriding the weekend and public holidays.
@Model
class WorkdayException {
    /// The day as `yyyy-MM-dd` in the user's calendar.
    @Attribute(.unique) var day: String
    var isWorkday: Bool
    var name: String

    init(day: String, isWorkday: Bool, name: String = "") {
        self.day = day
        self.isWorkday = isWorkday
        self.name = name
    }
}

/// When a schedule runs. The time of day comes from `start`; days come from the frequency
/// and its day lists, or from `workdayPosition`, and then from `workdays`.
struct ScheduleRule: Codable, Hashable {

    enum Frequency: String, Codable, CaseIterable, Identifiable {
        case once, hourly, daily, weekly, monthly, yearly

        var id: Self { self }
    }

    /// How a run relates to workdays.
    enum WorkdayMode: String, Codable, CaseIterable, Identifiable {
        /// Run on the named day whatever it is.
        case any
        /// Skip a named day that is not a workday.
        case only
        /// Move a named day that is not a workday to the next workday.
        case next
        /// Move a named day that is not a workday to the previous workday.
        case previous

        var id: Self { self }
    }

    var frequency: Frequency
    /// The first moment a run can happen.
    var start: Date
    /// Runs every this many hours, days, weeks, months, or years.
    var interval: Int = 1
    /// `Calendar` weekday numbers, where 1 is Sunday, for weekly rules.
    var weekdays: [Int] = []
    /// Days of the month, where -1 is the last day, for monthly and yearly rules.
    var monthDays: [Int] = []
    /// Months of the year, for yearly rules.
    var months: [Int] = []
    var workdays: WorkdayMode = .any
    /// The workday of each week (weekly), month (monthly), or listed month (yearly) to run on:
    /// 1 is the first and -1 the last. When set, it replaces `weekdays` and `monthDays`.
    var workdayPosition: Int?
    /// No run happens after this moment.
    var end: Date?

    /// Checks the combination of fields and fills the day lists the frequency needs from
    /// `start`.
    func validated(calendar: Calendar = .current) throws -> ScheduleRule {
        guard (1...1000).contains(interval) else { throw ScheduleRuleError.invalidInterval }
        if !weekdays.isEmpty, frequency != .weekly { throw ScheduleRuleError.weekdaysNeedWeekly }
        if !monthDays.isEmpty, frequency != .monthly, frequency != .yearly {
            throw ScheduleRuleError.monthDaysNeedMonthlyOrYearly
        }
        if !months.isEmpty, frequency != .yearly { throw ScheduleRuleError.monthsNeedYearly }
        guard weekdays.allSatisfy((1...7).contains) else { throw ScheduleRuleError.invalidWeekday }
        guard monthDays.allSatisfy({ (1...31).contains($0) || $0 == -1 }) else {
            throw ScheduleRuleError.invalidMonthDay
        }
        guard months.allSatisfy((1...12).contains) else { throw ScheduleRuleError.invalidMonth }
        if let workdayPosition {
            guard [.weekly, .monthly, .yearly].contains(frequency) else {
                throw ScheduleRuleError.positionNeedsPeriod
            }
            guard workdayPosition != 0, abs(workdayPosition) <= 23 else {
                throw ScheduleRuleError.invalidPosition
            }
            guard weekdays.isEmpty, monthDays.isEmpty else {
                throw ScheduleRuleError.positionWithDays
            }
        }
        if frequency == .hourly, workdays == .next || workdays == .previous {
            throw ScheduleRuleError.hourlyMove
        }
        if let end, end <= start { throw ScheduleRuleError.endBeforeStart }

        var rule = self
        if workdayPosition != nil {
            rule.workdays = .any
        }
        switch frequency {
        case .weekly where workdayPosition == nil && weekdays.isEmpty:
            rule.weekdays = [calendar.component(.weekday, from: start)]
        case .monthly where workdayPosition == nil && monthDays.isEmpty:
            rule.monthDays = [calendar.component(.day, from: start)]
        case .yearly:
            if months.isEmpty {
                rule.months = [calendar.component(.month, from: start)]
            }
            if workdayPosition == nil && monthDays.isEmpty {
                rule.monthDays = [calendar.component(.day, from: start)]
            }
        default:
            break
        }
        rule.weekdays = Array(Set(rule.weekdays)).sorted()
        rule.monthDays = Array(Set(rule.monthDays)).sorted()
        rule.months = Array(Set(rule.months)).sorted()
        return rule
    }
}

enum ScheduleRuleError: LocalizedError {
    case invalidInterval
    case weekdaysNeedWeekly
    case monthDaysNeedMonthlyOrYearly
    case monthsNeedYearly
    case invalidWeekday
    case invalidMonthDay
    case invalidMonth
    case positionNeedsPeriod
    case invalidPosition
    case positionWithDays
    case hourlyMove
    case endBeforeStart

    var errorDescription: String? {
        switch self {
        case .invalidInterval:
            String(localized: "The interval must be from 1 through 1000.")
        case .weekdaysNeedWeekly:
            String(localized: "Weekdays can be chosen only for a weekly schedule.")
        case .monthDaysNeedMonthlyOrYearly:
            String(localized: "Days of the month can be chosen only for a monthly or yearly schedule.")
        case .monthsNeedYearly:
            String(localized: "Months can be chosen only for a yearly schedule.")
        case .invalidWeekday:
            String(localized: "A weekday is not valid.")
        case .invalidMonthDay:
            String(localized: "Days of the month must be from 1 through 31, or -1 for the last day.")
        case .invalidMonth:
            String(localized: "Months must be from 1 through 12.")
        case .positionNeedsPeriod:
            String(localized: "A workday position needs a weekly, monthly, or yearly schedule.")
        case .invalidPosition:
            String(localized: "A workday position must be from 1 through 23 or from -1 through -23.")
        case .positionWithDays:
            String(localized: "A workday position replaces weekdays and days of the month; choose one or the other.")
        case .hourlyMove:
            String(localized: "An hourly schedule can only skip days that are not workdays, not move to another day.")
        case .endBeforeStart:
            String(localized: "The end must be after the start.")
        }
    }
}

// MARK: - Occurrences

extension ScheduleRule {

    /// The bound on periods or steps searched for a run, about twenty years of weekly runs.
    private static let searchLimit = 1000

    /// The first run strictly after `date`, or `nil` when the rule has no more runs.
    func nextRun(after date: Date, in workdayCalendar: WorkdayCalendar) -> Date? {
        let run = frequency == .hourly
            ? nextHourlyRun(after: date, in: workdayCalendar)
            : nextDayRun(after: date, in: workdayCalendar)
        guard let run else { return nil }
        if let end, run > end { return nil }
        return run
    }

    func nextRuns(after date: Date, count: Int, in workdayCalendar: WorkdayCalendar) -> [Date] {
        var runs: [Date] = []
        var cursor = date
        while runs.count < count, let run = nextRun(after: cursor, in: workdayCalendar) {
            runs.append(run)
            cursor = run
        }
        return runs
    }

    private func nextHourlyRun(after date: Date, in workdayCalendar: WorkdayCalendar) -> Date? {
        let step = TimeInterval(interval * 3600)
        var index = max(0, (date.timeIntervalSince(start) / step).rounded(.down) + 1)
        for _ in 0..<(Self.searchLimit * 24) {
            let run = start.addingTimeInterval(index * step)
            if let end, run > end { return nil }
            if workdays == .any || workdayCalendar.isWorkday(run) {
                return run
            }
            index += 1
        }
        return nil
    }

    private func nextDayRun(after date: Date, in workdayCalendar: WorkdayCalendar) -> Date? {
        let calendar = workdayCalendar.calendar
        let time = calendar.dateComponents([.hour, .minute, .second], from: start)
        // Moving a day off to a neighboring workday shifts it by at most a holiday's length,
        // so a day named a month before `date` can still run after it.
        let searchStart = max(calendar.date(byAdding: .day, value: -31, to: date)!, start)
        var result: Date?
        forEachNamedDay(from: searchStart, in: workdayCalendar) { day in
            guard let runDay = adjusted(day, in: workdayCalendar) else { return false }
            let run = calendar.date(
                bySettingHour: time.hour ?? 0,
                minute: time.minute ?? 0,
                second: time.second ?? 0,
                of: runDay)!
            if let end, run > end { return true }
            guard run > date, run >= start else { return false }
            result = run
            return true
        }
        return result
    }

    /// The day a named day runs on once `workdays` applies, or `nil` when it is skipped.
    private func adjusted(_ day: Date, in workdayCalendar: WorkdayCalendar) -> Date? {
        let calendar = workdayCalendar.calendar
        let step: Int
        switch workdays {
        case .any:
            return day
        case .only:
            return workdayCalendar.isWorkday(day) ? day : nil
        case .next:
            step = 1
        case .previous:
            step = -1
        }
        var candidate = day
        for _ in 0..<60 {
            if workdayCalendar.isWorkday(candidate) { return candidate }
            candidate = calendar.date(byAdding: .day, value: step, to: candidate)!
        }
        return nil
    }

    /// Calls `body` with the start of each day the rule names, in order, beginning with the
    /// period that contains `date`, until `body` returns `true`.
    private func forEachNamedDay(
        from date: Date,
        in workdayCalendar: WorkdayCalendar,
        _ body: (Date) -> Bool
    ) {
        let calendar = workdayCalendar.calendar
        let startDay = calendar.startOfDay(for: start)

        switch frequency {
        case .once:
            _ = body(startDay)
        case .hourly:
            break
        case .daily:
            let elapsed = calendar.dateComponents(
                [.day], from: startDay, to: calendar.startOfDay(for: date)).day ?? 0
            var offset = max(0, elapsed / interval * interval)
            for _ in 0..<(Self.searchLimit * 5) {
                if body(calendar.date(byAdding: .day, value: offset, to: startDay)!) { return }
                offset += interval
            }
        case .weekly:
            forEachPeriod(.weekOfYear, from: date, calendar: calendar) { period in
                if let workdayPosition {
                    return workday(at: workdayPosition, in: period, workdayCalendar: workdayCalendar)
                        .map(body) ?? false
                }
                let days = (0..<7)
                    .map { calendar.date(byAdding: .day, value: $0, to: period.start)! }
                    .filter { weekdays.contains(calendar.component(.weekday, from: $0)) }
                return days.contains(where: body)
            }
        case .monthly:
            forEachPeriod(.month, from: date, calendar: calendar) { period in
                if let workdayPosition {
                    return workday(at: workdayPosition, in: period, workdayCalendar: workdayCalendar)
                        .map(body) ?? false
                }
                return days(monthDays, in: period, calendar: calendar).contains(where: body)
            }
        case .yearly:
            forEachPeriod(.year, from: date, calendar: calendar) { year in
                for month in months {
                    let firstDay = calendar.date(byAdding: .month, value: month - 1, to: year.start)!
                    let period = calendar.dateInterval(of: .month, for: firstDay)!
                    let named = if let workdayPosition {
                        workday(at: workdayPosition, in: period, workdayCalendar: workdayCalendar).map { [$0] } ?? []
                    } else {
                        days(monthDays, in: period, calendar: calendar)
                    }
                    if named.contains(where: body) { return true }
                }
                return false
            }
        }
    }

    /// Calls `body` with every `interval`-th period counted from the one containing `start`,
    /// beginning at the period that contains `date`, until `body` returns `true`.
    private func forEachPeriod(
        _ component: Calendar.Component,
        from date: Date,
        calendar: Calendar,
        _ body: (DateInterval) -> Bool
    ) {
        let first = calendar.dateInterval(of: component, for: start)!.start
        let current = calendar.dateInterval(of: component, for: date)!.start
        let elapsed = calendar.dateComponents([component], from: first, to: current)
            .value(for: component) ?? 0
        var offset = max(0, elapsed / interval * interval)
        for _ in 0..<Self.searchLimit {
            let periodStart = calendar.date(byAdding: component, value: offset, to: first)!
            if body(calendar.dateInterval(of: component, for: periodStart)!) { return }
            offset += interval
        }
    }

    /// The listed days of the month that exist in `month`, in order; -1 is the last day.
    private func days(_ monthDays: [Int], in month: DateInterval, calendar: Calendar) -> [Date] {
        let count = calendar.range(of: .day, in: .month, for: month.start)!.count
        return Set(monthDays.map { $0 == -1 ? count : $0 })
            .filter { $0 <= count }
            .sorted()
            .map { calendar.date(byAdding: .day, value: $0 - 1, to: month.start)! }
    }

    /// The `position`-th workday in `period`, counting from the end when negative.
    private func workday(at position: Int, in period: DateInterval, workdayCalendar: WorkdayCalendar) -> Date? {
        let calendar = workdayCalendar.calendar
        var days: [Date] = []
        var day = period.start
        while day < period.end {
            if workdayCalendar.isWorkday(day) { days.append(day) }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        let index = position > 0 ? position - 1 : days.count + position
        return days.indices.contains(index) ? days[index] : nil
    }
}

// MARK: - Description

extension ScheduleRule {

    var localizedDescription: String {
        let calendar = Calendar.current
        let time = start.formatted(date: .omitted, time: .shortened)
        let weekdayNames = weekdays.map { calendar.weekdaySymbols[$0 - 1] }.formatted(.list(type: .and))
        let dayNames = monthDays
            .map { $0 == -1 ? String(localized: "the last day") : $0.formatted() }
            .formatted(.list(type: .and))
        let monthNames = months.map { calendar.monthSymbols[$0 - 1] }.formatted(.list(type: .and))
        let position = workdayPosition.map(Self.positionDescription)

        var text = switch frequency {
        case .once:
            String(localized: "Once on \(start.formatted(date: .abbreviated, time: .shortened))")
        case .hourly:
            interval == 1
                ? String(localized: "Every hour")
                : String(localized: "Every \(interval) hours")
        case .daily:
            interval == 1
                ? String(localized: "Every day at \(time)")
                : String(localized: "Every \(interval) days at \(time)")
        case .weekly:
            interval == 1
                ? String(localized: "Every week on \(position ?? weekdayNames) at \(time)")
                : String(localized: "Every \(interval) weeks on \(position ?? weekdayNames) at \(time)")
        case .monthly:
            interval == 1
                ? String(localized: "Every month on \(position ?? String(localized: "day \(dayNames)")) at \(time)")
                : String(localized: "Every \(interval) months on \(position ?? String(localized: "day \(dayNames)")) at \(time)")
        case .yearly:
            interval == 1
                ? String(localized: "Every year in \(monthNames) on \(position ?? String(localized: "day \(dayNames)")) at \(time)")
                : String(localized: "Every \(interval) years in \(monthNames) on \(position ?? String(localized: "day \(dayNames)")) at \(time)")
        }
        switch workdays {
        case .any:
            break
        case .only:
            text = String(localized: "\(text), workdays only")
        case .next:
            text = String(localized: "\(text), moved to the next workday on days off")
        case .previous:
            text = String(localized: "\(text), moved to the previous workday on days off")
        }
        if let end {
            text = String(localized: "\(text), until \(end.formatted(date: .abbreviated, time: .shortened))")
        }
        return text
    }

    static func positionDescription(_ position: Int) -> String {
        switch position {
        case 1: String(localized: "the first workday")
        case 2: String(localized: "the second workday")
        case 3: String(localized: "the third workday")
        case -1: String(localized: "the last workday")
        case -2: String(localized: "the second-to-last workday")
        case let position where position > 0: String(localized: "workday \(position)")
        default: String(localized: "workday \(-position) from the end")
        }
    }
}
