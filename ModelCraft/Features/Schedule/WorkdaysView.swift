//
//  WorkdaysView.swift
//  ModelCraft
//
//  Created by Hongshen on 24/10/26.
//

import SwiftUI
import SwiftData

struct WorkdaysView: View {

    private struct Region: Identifiable {
        let code: String
        let name: String

        var id: String { code }
    }

    @Query(sort: \WorkdayException.day) private var exceptions: [WorkdayException]
    @State private var newDate = Date.now
    @State private var newIsWorkday = false
    @State private var newName = ""

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private static let regions: [Region] = Locale.Region.isoRegions
        .map(\.identifier)
        .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
        .map { Region(code: $0, name: Locale.current.localizedString(forRegionCode: $0) ?? $0) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    /// How far ahead the coming special days are listed.
    private static let upcomingDays = 120

    var body: some View {
        @Bindable var store = HolidayStore.shared
        let workdays = store.workdayCalendar(exceptions: exceptions)
        Form {
            Section {
                Picker("Holiday Region", selection: $store.region) {
                    Text("None").tag("")
                    ForEach(Self.regions) { region in
                        Text(region.name).tag(region.code)
                    }
                }
                if !store.region.isEmpty, !store.unavailableYears.isEmpty {
                    let years = store.unavailableYears.sorted()
                        .map { $0.formatted(.number.grouping(.never)) }
                        .formatted(.list(type: .and))
                    Label(
                        "Public holidays for \(years) aren't available yet. Until they load, those years follow the weekend only.",
                        systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Workdays are the days outside the weekend, adjusted for the region's public holidays and, in mainland China, its makeup workdays. Exceptions take precedence over both.")
            }

            Section("Coming Up") {
                let days = upcomingSpecialDays(in: workdays)
                if days.isEmpty {
                    Text("No holidays or exceptions in the coming months")
                        .foregroundStyle(.secondary)
                }
                ForEach(days, id: \.date) { day in
                    SpecialDayRow(day: day)
                }
            }

            Section("Exceptions") {
                ForEach(exceptions) { exception in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(WorkdayCalendar.date(forKey: exception.day)?
                                .formatted(date: .complete, time: .omitted) ?? exception.day)
                            if !exception.name.isEmpty {
                                Text(exception.name)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        exception.isWorkday ? Text("Workday") : Text("Day Off")
                        Button {
                            modelContext.delete(exception)
                            try? modelContext.save()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove Exception")
                    }
                }
                HStack {
                    DatePicker("Date", selection: $newDate, displayedComponents: .date)
                        .labelsHidden()
                    Picker("Kind", selection: $newIsWorkday) {
                        Text("Day Off").tag(false)
                        Text("Workday").tag(true)
                    }
                    .labelsHidden()
                    .fixedSize()
                    TextField("Name", text: $newName, prompt: Text("Reason (optional)"))
                    Button("Add", action: addException)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 520)
        .task { await HolidayStore.shared.refresh() }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }

    /// Days in the coming months whose workday status differs from the weekly pattern.
    private func upcomingSpecialDays(in workdays: WorkdayCalendar) -> [WorkdayCalendar.Day] {
        let calendar = workdays.calendar
        let today = calendar.startOfDay(for: .now)
        return (0..<Self.upcomingDays).compactMap { offset in
            let day = workdays.day(calendar.date(byAdding: .day, value: offset, to: today)!)
            switch day.reason {
            case .weekday, .weekend: return nil
            case .holiday, .makeupWorkday, .exception: return day
            }
        }
    }

    private func addException() {
        let key = WorkdayCalendar.key(for: newDate)
        for exception in exceptions where exception.day == key {
            modelContext.delete(exception)
        }
        modelContext.insert(WorkdayException(
            day: key,
            isWorkday: newIsWorkday,
            name: newName.trimmingCharacters(in: .whitespacesAndNewlines)))
        try? modelContext.save()
        newName = ""
    }
}

private struct SpecialDayRow: View {

    let day: WorkdayCalendar.Day

    private var name: String {
        switch day.reason {
        case .weekday, .weekend: ""
        case .holiday(let name), .makeupWorkday(let name): name
        case .exception(let name): name.isEmpty ? String(localized: "Exception") : name
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(day.date.formatted(date: .complete, time: .omitted))
                Text(name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            day.isWorkday ? Text("Workday") : Text("Day Off")
        }
    }
}

#if DEBUG
#Preview(traits: .preview) {
    WorkdaysView()
}
#endif
