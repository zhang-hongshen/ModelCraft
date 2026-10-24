//
//  WorkdayCalendar.swift
//  ModelCraft
//
//  Created by Hongshen on 24/10/26.
//

import Foundation
import SwiftData

/// A day whose workday status differs from the weekly pattern.
struct SpecialDay: Codable, Hashable {
    /// The day as `yyyy-MM-dd`.
    let date: String
    let name: String
    let isOffDay: Bool
}

/// Decides which days are workdays: the user's exceptions first, then the holiday region's
/// public holidays and makeup workdays, then the locale's weekend.
struct WorkdayCalendar {

    enum Reason: Hashable {
        case weekday, weekend
        case holiday(String)
        case makeupWorkday(String)
        case exception(String)
    }

    struct Day: Hashable {
        let date: Date
        let isWorkday: Bool
        let reason: Reason
    }

    var calendar: Calendar = .current
    let holidays: [String: SpecialDay]
    let exceptions: [String: SpecialDay]

    func isWorkday(_ date: Date) -> Bool {
        day(date).isWorkday
    }

    func day(_ date: Date) -> Day {
        let key = Self.key(for: date, calendar: calendar)
        if let exception = exceptions[key] {
            return Day(date: date, isWorkday: !exception.isOffDay, reason: .exception(exception.name))
        }
        if let holiday = holidays[key] {
            return Day(
                date: date,
                isWorkday: !holiday.isOffDay,
                reason: holiday.isOffDay ? .holiday(holiday.name) : .makeupWorkday(holiday.name))
        }
        let isWeekend = calendar.isDateInWeekend(date)
        return Day(date: date, isWorkday: !isWeekend, reason: isWeekend ? .weekend : .weekday)
    }

    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    static func date(forKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components),
              key == Self.key(for: date, calendar: calendar)
        else { return nil }
        return date
    }
}

/// Public holidays of the holiday region, fetched once per year and cached on disk.
@MainActor
@Observable
final class HolidayStore {

    static let shared = HolidayStore()

    /// The ISO region code whose public holidays count, or an empty string for none.
    var region = UserDefaults.standard.string(forKey: UserDefaults.holidayRegion)
        ?? UserDefaultSettings.holidayRegion {
        didSet {
            UserDefaults.standard.set(region, forKey: UserDefaults.holidayRegion)
            holidays = [:]
            loadedYears = []
            unavailableYears = []
            Task { await refresh() }
        }
    }

    private(set) var holidays: [String: SpecialDay] = [:]
    private(set) var loadedYears: Set<Int> = []
    /// Years whose holidays could not be loaded; their workdays follow the weekend only.
    private(set) var unavailableYears: Set<Int> = []

    private static let cacheDirectory = UserDefaultSettings.modelDownloadBaseDirectory
        .appending(path: "Holidays")

    private init() {}

    func workdayCalendar() -> WorkdayCalendar {
        workdayCalendar(exceptions: (try? ModelContainer.shared.mainContext.fetch(
            FetchDescriptor<WorkdayException>())) ?? [])
    }

    func workdayCalendar(exceptions: [WorkdayException]) -> WorkdayCalendar {
        WorkdayCalendar(
            holidays: holidays,
            exceptions: Dictionary(exceptions.map {
                ($0.day, SpecialDay(date: $0.day, name: $0.name, isOffDay: !$0.isWorkday))
            }, uniquingKeysWith: { first, _ in first }))
    }

    /// Loads the holidays of this year and the next that are not loaded yet. A year that has
    /// not been published is tried again on the next refresh.
    func refresh() async {
        guard !region.isEmpty else { return }
        let region = region
        let year = Calendar.current.component(.year, from: .now)
        for year in [year, year + 1] where !loadedYears.contains(year) {
            let cacheURL = Self.cacheDirectory.appending(path: "\(region)-\(year).json")
            let days: [SpecialDay]
            if let data = try? Data(contentsOf: cacheURL),
               let cached = try? JSONDecoder().decode([SpecialDay].self, from: data) {
                days = cached
            } else {
                do {
                    days = try await Self.fetchDays(region: region, year: year)
                    try FileManager.default.createDirectory(
                        at: Self.cacheDirectory, withIntermediateDirectories: true)
                    try JSONEncoder().encode(days).write(to: cacheURL)
                } catch {
                    guard region == self.region else { return }
                    unavailableYears.insert(year)
                    continue
                }
            }
            // The region may have changed while the year was loading.
            guard region == self.region else { return }
            for day in days {
                holidays[day.date] = day
            }
            loadedYears.insert(year)
            unavailableYears.remove(year)
        }
    }

    /// Mainland China's holidays come with their makeup workdays from the State Council
    /// schedule; other regions list nationwide public holidays only.
    private static func fetchDays(region: String, year: Int) async throws -> [SpecialDay] {
        if region == "CN" {
            struct Response: Decodable {
                let days: [SpecialDay]
            }
            let url = URL(string: "https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/\(year).json")!
            let days = try JSONDecoder().decode(Response.self, from: try await data(from: url)).days
            guard !days.isEmpty else { throw HolidayStoreError.unavailable }
            return days
        }
        struct Holiday: Decodable {
            let date: String
            let localName: String
            let global: Bool
            let types: [String]
        }
        let url = URL(string: "https://date.nager.at/api/v3/PublicHolidays/\(year)/\(region)")!
        return try JSONDecoder().decode([Holiday].self, from: try await data(from: url))
            .filter { $0.global && $0.types.contains("Public") }
            .map { SpecialDay(date: $0.date, name: $0.localName, isOffDay: true) }
    }

    private static func data(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw HolidayStoreError.unavailable
        }
        return data
    }
}

private enum HolidayStoreError: Error {
    case unavailable
}
