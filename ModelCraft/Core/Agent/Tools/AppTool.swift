//
//  AppTool.swift
//  ModelCraft
//

import EventKit
import Foundation
import MLXLMCommon

enum AppTool {

    static let allTools: [any ToolProtocol] = [
        searchNotes, readNote, createNote, updateNote,
        searchCalendar, readCalendarEvent, createCalendarEvent, updateCalendarEvent,
        searchReminders, readReminder, createReminder, updateReminder,
        searchMail, readMail, createMailDraft,
        runAppleScript,
    ]

    static let searchNotes = Tool<SearchNotesInput, [NoteSummary]>(
        name: ToolNames.searchNotes,
        description: "Search Apple Notes by title or plain-text content and return matching note identifiers, folders, modification dates, and excerpts. This is read-only and should be preferred over accessibility or screenshots for Notes. Use notes_read with a returned note_id to retrieve the full content.",
        parameters: [
            .required("query", type: .string, description: "Text to find in note titles or plain-text content. Use an empty string only when listing notes in a known folder."),
            .optional("folder", type: .string, description: "Exact Notes folder name to search. Omit to search all folders."),
            .optional("limit", type: .int, description: "Maximum number of results. Omit to return up to 20; values are clamped to 1 through 100.")
        ]
    ) { input in
        let query = AppleScriptLiteral.string(input.query)
        let folder = AppleScriptLiteral.string(input.folder ?? "")
        let limit = min(max(input.limit ?? 20, 1), 100)
        let source = """
            set queryText to \(query)
            set requestedFolder to \(folder)
            set maximumCount to \(limit)
            set resultRows to {}

            tell application id "com.apple.Notes"
                repeat with accountItem in accounts
                    repeat with folderItem in folders of accountItem
                        set folderName to name of folderItem as text
                        if requestedFolder is "" or folderName is requestedFolder then
                            repeat with noteItem in notes of folderItem
                                if (count of resultRows) < maximumCount then
                                    set noteName to name of noteItem as text
                                    set noteText to plaintext of noteItem as text
                                    if queryText is "" or noteName contains queryText or noteText contains queryText then
                                        set previewText to noteText
                                        if (length of previewText) > 400 then
                                            set previewText to text 1 thru 400 of previewText
                                        end if
                                        set end of resultRows to {id of noteItem as text, noteName, folderName, (modification date of noteItem) as text, previewText}
                                    end if
                                end if
                            end repeat
                        end if
                    end repeat
                end repeat
            end tell
            return resultRows
            """
        let result = try await AppleScriptRunner.run(source, in: NativeApplication.notes.bundleIdentifier)
        return rows(from: result).map { row in
            NoteSummary(
                noteID: row[0],
                title: row[1],
                folder: row[2],
                modificationDate: row[3],
                excerpt: row[4])
        }
    }

    static let readNote = Tool<ReadNoteInput, NoteDetail>(
        name: ToolNames.readNote,
        description: "Read one Apple Note by the stable note_id returned from notes_search. This is read-only and returns the full plain-text content plus note metadata.",
        parameters: [
            .required("note_id", type: .string, description: "Stable Notes identifier returned by notes_search.")
        ]
    ) { input in
        let noteID = AppleScriptLiteral.string(input.noteID)
        let source = """
            set requestedID to \(noteID)
            tell application id "com.apple.Notes"
                repeat with accountItem in accounts
                    repeat with noteItem in notes of accountItem
                        if (id of noteItem as text) is requestedID then
                            return {id of noteItem as text, name of noteItem as text, name of container of noteItem as text, plaintext of noteItem as text, (creation date of noteItem) as text, (modification date of noteItem) as text, password protected of noteItem}
                        end if
                    end repeat
                end repeat
            end tell
            error "Note not found." number -1728
            """
        let result = try await AppleScriptRunner.run(source, in: NativeApplication.notes.bundleIdentifier)
        let row = stringRow(from: result)
        return NoteDetail(
            noteID: row[0],
            title: row[1],
            folder: row[2],
            content: row[3],
            creationDate: row[4],
            modificationDate: row[5],
            passwordProtected: row[6] == "true")
    }

    static let createNote = Tool<CreateNoteInput, NoteMutationResult>(
        name: ToolNames.createNote,
        description: "Create a new Apple Note in the requested folder or the default Notes folder. This writes user data and requires confirmation before execution. It returns the created note_id, title, and folder.",
        parameters: [
            .required("title", type: .string, description: "Title for the new note."),
            .required("body", type: .string, description: "Plain-text body for the new note."),
            .optional("folder", type: .string, description: "Exact Notes folder name. Omit to use the default folder of the default account.")
        ]
    ) { input in
        let title = AppleScriptLiteral.string(input.title)
        let body = AppleScriptLiteral.string(
            NotesHTML.body(fromPlainText: input.body))
        let folder = AppleScriptLiteral.string(input.folder ?? "")
        let source = """
            set requestedTitle to \(title)
            set requestedBody to \(body)
            set requestedFolder to \(folder)
            tell application id "com.apple.Notes"
                set targetAccount to default account
                set targetFolder to default folder of targetAccount
                if requestedFolder is not "" then
                    set folderFound to false
                    repeat with folderItem in folders of targetAccount
                        if (name of folderItem as text) is requestedFolder then
                            set targetFolder to folderItem
                            set folderFound to true
                            exit repeat
                        end if
                    end repeat
                    if folderFound is false then error "Notes folder not found." number -1728
                end if
                set createdNote to make new note at targetFolder with properties {name:requestedTitle, body:requestedBody}
                return {id of createdNote as text, name of createdNote as text, name of targetFolder as text}
            end tell
            """
        let result = try await AppleScriptRunner.run(source, in: NativeApplication.notes.bundleIdentifier)
        let row = stringRow(from: result)
        return NoteMutationResult(noteID: row[0], title: row[1], folder: row[2])
    }

    static let updateNote = Tool<UpdateNoteInput, NoteMutationResult>(
        name: ToolNames.updateNote,
        description: "Update the title and/or plain-text body of an existing Apple Note. This writes user data and requires confirmation before execution. Pass a note_id returned by notes_search; omit fields that should remain unchanged.",
        parameters: [
            .required("note_id", type: .string, description: "Stable Notes identifier returned by notes_search."),
            .optional("title", type: .string, description: "Replacement title. Omit to preserve the current title."),
            .optional("body", type: .string, description: "Replacement plain-text body. Omit to preserve the current body.")
        ]
    ) { input in
        guard input.title != nil || input.body != nil else {
            throw AppToolError.noChanges
        }
        let noteID = AppleScriptLiteral.string(input.noteID)
        let title = input.title.map(AppleScriptLiteral.string) ?? "missing value"
        let body = input.body.map {
            AppleScriptLiteral.string(NotesHTML.body(fromPlainText: $0))
        } ?? "missing value"
        let source = """
            set requestedID to \(noteID)
            set replacementTitle to \(title)
            set replacementBody to \(body)
            tell application id "com.apple.Notes"
                repeat with accountItem in accounts
                    repeat with noteItem in notes of accountItem
                        if (id of noteItem as text) is requestedID then
                            if password protected of noteItem then error "Password-protected notes cannot be modified." number -10000
                            if replacementTitle is not missing value then set name of noteItem to replacementTitle
                            if replacementBody is not missing value then set body of noteItem to replacementBody
                            return {id of noteItem as text, name of noteItem as text, name of container of noteItem as text}
                        end if
                    end repeat
                end repeat
            end tell
            error "Note not found." number -1728
            """
        let result = try await AppleScriptRunner.run(source, in: NativeApplication.notes.bundleIdentifier)
        let row = stringRow(from: result)
        return NoteMutationResult(noteID: row[0], title: row[1], folder: row[2])
    }

    static let searchMail = Tool<SearchMailInput, [MailSummary]>(
        name: ToolNames.searchMail,
        description: "Search Apple Mail message subjects and senders, optionally within one account or mailbox. This is read-only and should be preferred over accessibility or screenshots for Mail. It returns message identifiers and excerpts; use mail_read with the returned message_id, account, and mailbox for full content.",
        parameters: [
            .required("query", type: .string, description: "Text to find in message subjects or sender values."),
            .optional("account", type: .string, description: "Exact Mail account name. Omit to search all accounts."),
            .optional("mailbox", type: .string, description: "Exact mailbox name. Omit to search all mailboxes."),
            .optional("unread_only", type: .bool, description: "Set true to return only unread messages. Omit or false to include both read and unread messages."),
            .optional("limit", type: .int, description: "Maximum number of results. Omit to return up to 20; values are clamped to 1 through 100.")
        ]
    ) { input in
        let query = AppleScriptLiteral.string(input.query)
        let account = AppleScriptLiteral.string(input.account ?? "")
        let mailbox = AppleScriptLiteral.string(input.mailbox ?? "")
        let unreadOnly = input.unreadOnly ?? false
        let limit = min(max(input.limit ?? 20, 1), 100)
        let source = """
            set queryText to \(query)
            set requestedAccount to \(account)
            set requestedMailbox to \(mailbox)
            set unreadOnly to \(unreadOnly)
            set maximumCount to \(limit)
            set resultRows to {}

            tell application id "com.apple.mail"
                repeat with accountItem in accounts
                    set accountName to name of accountItem as text
                    if requestedAccount is "" or accountName is requestedAccount then
                        repeat with mailboxItem in mailboxes of accountItem
                            set mailboxName to name of mailboxItem as text
                            if requestedMailbox is "" or mailboxName is requestedMailbox then
                                repeat with messageItem in messages of mailboxItem
                                    if (count of resultRows) < maximumCount then
                                        set messageSubject to subject of messageItem as text
                                        set messageSender to sender of messageItem as text
                                        set messageUnread to not (read status of messageItem)
                                        if (unreadOnly is false or messageUnread) and (queryText is "" or messageSubject contains queryText or messageSender contains queryText) then
                                            set messagePreview to content of messageItem as text
                                            if (length of messagePreview) > 400 then set messagePreview to text 1 thru 400 of messagePreview
                                            set end of resultRows to {id of messageItem as text, messageSubject, messageSender, (date received of messageItem) as text, accountName, mailboxName, messageUnread, messagePreview}
                                        end if
                                    end if
                                end repeat
                            end if
                        end repeat
                    end if
                end repeat
            end tell
            return resultRows
            """
        let result = try await AppleScriptRunner.run(source, in: NativeApplication.mail.bundleIdentifier)
        return rows(from: result).map { row in
            MailSummary(
                messageID: row[0],
                subject: row[1],
                sender: row[2],
                dateReceived: row[3],
                account: row[4],
                mailbox: row[5],
                unread: row[6] == "true",
                excerpt: row[7])
        }
    }

    static let readMail = Tool<ReadMailInput, MailDetail>(
        name: ToolNames.readMail,
        description: "Read one Apple Mail message by the message_id, account, and mailbox returned from mail_search. This is read-only and does not change the message read status. It returns headers, mailbox location, and bounded message content.",
        parameters: [
            .required("message_id", type: .string, description: "Mail message identifier returned by mail_search."),
            .required("account", type: .string, description: "Exact Mail account name returned with the search result."),
            .required("mailbox", type: .string, description: "Exact mailbox name returned with the search result."),
            .optional("max_content_length", type: .int, description: "Maximum number of message characters to return. Omit to use 12000; values are clamped to 1 through 50000.")
        ]
    ) { input in
        let messageID = AppleScriptLiteral.string(input.messageID)
        let account = AppleScriptLiteral.string(input.account)
        let mailbox = AppleScriptLiteral.string(input.mailbox)
        let maximumLength = min(max(input.maxContentLength ?? 12_000, 1), 50_000)
        let source = """
            set requestedID to \(messageID)
            set requestedAccount to \(account)
            set requestedMailbox to \(mailbox)
            set maximumLength to \(maximumLength)
            tell application id "com.apple.mail"
                repeat with accountItem in accounts
                    set accountName to name of accountItem as text
                    if accountName is requestedAccount then
                        repeat with mailboxItem in mailboxes of accountItem
                            set mailboxName to name of mailboxItem as text
                            if mailboxName is requestedMailbox then
                                repeat with messageItem in messages of mailboxItem
                                    if (id of messageItem as text) is requestedID then
                                        set messageContent to content of messageItem as text
                                        if (length of messageContent) > maximumLength then set messageContent to text 1 thru maximumLength of messageContent
                                        set internetID to message id of messageItem
                                        if internetID is missing value then set internetID to ""
                                        return {id of messageItem as text, subject of messageItem as text, sender of messageItem as text, (date received of messageItem) as text, accountName, mailboxName, read status of messageItem, internetID as text, messageContent}
                                    end if
                                end repeat
                            end if
                        end repeat
                    end if
                end repeat
            end tell
            error "Mail message not found." number -1728
            """
        let result = try await AppleScriptRunner.run(source, in: NativeApplication.mail.bundleIdentifier)
        let row = stringRow(from: result)
        return MailDetail(
            messageID: row[0],
            subject: row[1],
            sender: row[2],
            dateReceived: row[3],
            account: row[4],
            mailbox: row[5],
            read: row[6] == "true",
            internetMessageID: row[7],
            content: row[8])
    }

    static let createMailDraft = Tool<CreateMailDraftInput, MailDraftResult>(
        name: ToolNames.createMailDraft,
        description: "Create and save an Apple Mail draft without sending it. This writes user data and requires confirmation before execution. The tool never sends mail and returns the draft identifier and subject.",
        parameters: [
            .required("to", type: .array(elementType: .string), description: "One or more recipient email addresses for the draft.", extraProperties: ["minItems": 1]),
            .optional("cc", type: .array(elementType: .string), description: "CC recipient email addresses."),
            .optional("bcc", type: .array(elementType: .string), description: "BCC recipient email addresses."),
            .required("subject", type: .string, description: "Draft subject."),
            .required("body", type: .string, description: "Plain-text draft body.")
        ]
    ) { input in
        let toRecipients = AppleScriptLiteral.stringList(input.to)
        let ccRecipients = AppleScriptLiteral.stringList(input.cc ?? [])
        let bccRecipients = AppleScriptLiteral.stringList(input.bcc ?? [])
        let subject = AppleScriptLiteral.string(input.subject)
        let body = AppleScriptLiteral.string(input.body)
        let source = """
            set toAddresses to \(toRecipients)
            set ccAddresses to \(ccRecipients)
            set bccAddresses to \(bccRecipients)
            set draftSubject to \(subject)
            set draftBody to \(body)

            tell application id "com.apple.mail"
                set draftMessage to make new outgoing message with properties {subject:draftSubject, content:draftBody, visible:false}
                tell draftMessage
                    repeat with recipientAddress in toAddresses
                        make new to recipient at end of to recipients with properties {address:recipientAddress as text}
                    end repeat
                    repeat with recipientAddress in ccAddresses
                        make new cc recipient at end of cc recipients with properties {address:recipientAddress as text}
                    end repeat
                    repeat with recipientAddress in bccAddresses
                        make new bcc recipient at end of bcc recipients with properties {address:recipientAddress as text}
                    end repeat
                    save
                end tell
                return {id of draftMessage as text, subject of draftMessage as text}
            end tell
            """
        let result = try await AppleScriptRunner.run(source, in: NativeApplication.mail.bundleIdentifier)
        let row = stringRow(from: result)
        return MailDraftResult(draftID: row[0], subject: row[1], sent: false)
    }

    static let runAppleScript = Tool<RunAppleScriptInput, RunAppleScriptOutput>(
        name: ToolNames.runAppleScript,
        description: "Run raw AppleScript only when no typed native-application tool covers the requested operation. Prefer Notes, Reminders, Calendar, or Mail tools whenever possible. Every call requires user confirmation and shows the complete script. Returns the script's result as text.",
        parameters: [
            .required("script", type: .string, description: "Complete AppleScript source to execute. The full source is shown to the user."),
            .required("target_app_bundle_id", type: .string, description: "Bundle identifier of the primary application controlled by the script. ModelCraft launches it without activation when it is not running.")
        ]
    ) { input in
        let result = try await AppleScriptRunner.run(input.script, in: input.targetAppBundleID)
        return RunAppleScriptOutput(result: AppleScriptRunner.text(of: result))
    }

    private static func rows(from result: NSAppleEventDescriptor) -> [[String]] {
        AppleScriptRunner.items(of: result).map(stringRow(from:))
    }

    private static func stringRow(from result: NSAppleEventDescriptor) -> [String] {
        AppleScriptRunner.items(of: result).map(AppleScriptRunner.text(of:))
    }

    static let searchCalendar = Tool<SearchCalendarInput, [CalendarEventOutput]>(
        name: ToolNames.searchCalendar,
        description: "Search macOS Calendar through EventKit within a required time range. This is read-only and should be preferred over Calendar UI automation. It returns stable event identifiers and event details for calendar_read or calendar_update.",
        parameters: [
            .required("start_at", type: .string, description: "Inclusive ISO 8601 start date and time with a time zone."),
            .required("end_at", type: .string, description: "Exclusive ISO 8601 end date and time with a time zone; it must be later than start_at."),
            .optional("query", type: .string, description: "Text to find in event titles, locations, or notes. Omit to return all events in the range."),
            .optional("calendar", type: .string, description: "Exact calendar title. Omit to search all calendars."),
            .optional("limit", type: .int, description: "Maximum number of results. Omit to use 20; values are clamped to 1 through 100.")
        ]
    ) { input in
        try await NativeEventStore.shared.searchEvents(input)
    }

    static let readCalendarEvent = Tool<ReadCalendarEventInput, CalendarEventOutput>(
        name: ToolNames.readCalendarEvent,
        description: "Read one Calendar event through EventKit by the event_id returned from calendar_search. This is read-only.",
        parameters: [
            .required("event_id", type: .string, description: "Stable Calendar event identifier returned by calendar_search.")
        ]
    ) { input in
        try await NativeEventStore.shared.readEvent(identifier: input.eventID)
    }

    static let createCalendarEvent = Tool<CreateCalendarEventInput, CalendarEventOutput>(
        name: ToolNames.createCalendarEvent,
        description: "Create a Calendar event through EventKit. This writes calendar data and requires confirmation before execution. It returns the saved event identifier and full event details.",
        parameters: [
            .required("title", type: .string, description: "Event title."),
            .required("start_at", type: .string, description: "ISO 8601 start date and time with a time zone."),
            .required("end_at", type: .string, description: "ISO 8601 end date and time with a time zone; it must be later than start_at."),
            .optional("calendar", type: .string, description: "Exact calendar title. Omit to use the system default calendar for new events."),
            .optional("all_day", type: .bool, description: "Set true for an all-day event. Omit to use false."),
            .optional("location", type: .string, description: "Event location."),
            .optional("notes", type: .string, description: "Event notes.")
        ]
    ) { input in
        try await NativeEventStore.shared.createEvent(input)
    }

    static let updateCalendarEvent = Tool<UpdateCalendarEventInput, CalendarEventOutput>(
        name: ToolNames.updateCalendarEvent,
        description: "Update an existing Calendar event through EventKit. This writes calendar data and requires confirmation before execution. For a recurring event, span controls whether only this occurrence or this and future occurrences change.",
        parameters: [
            .required("event_id", type: .string, description: "Stable Calendar event identifier returned by calendar_search."),
            .optional("title", type: .string, description: "Replacement event title."),
            .optional("start_at", type: .string, description: "Replacement ISO 8601 start date and time with a time zone."),
            .optional("end_at", type: .string, description: "Replacement ISO 8601 end date and time with a time zone."),
            .optional("calendar", type: .string, description: "Exact destination calendar title."),
            .optional("all_day", type: .bool, description: "Replacement all-day setting."),
            .optional("location", type: .string, description: "Replacement location. Pass an empty string to clear it."),
            .optional("notes", type: .string, description: "Replacement notes. Pass an empty string to clear them."),
            .optional("span", type: .string, description: "Recurring-event update scope: `this_event` or `future_events`. Omit to use `this_event`.", extraProperties: ["enum": ["this_event", "future_events"]])
        ]
    ) { input in
        try await NativeEventStore.shared.updateEvent(input)
    }

    static let searchReminders = Tool<SearchRemindersInput, [ReminderOutput]>(
        name: ToolNames.searchReminders,
        description: "Search macOS Reminders through EventKit by title and notes, optionally filtering by list, completion state, and due-date range. This is read-only and should be preferred over Reminders UI automation.",
        parameters: [
            .optional("query", type: .string, description: "Text to find in reminder titles or notes. Omit to list reminders matching the other filters."),
            .optional("list", type: .string, description: "Exact reminder-list title. Omit to search all lists."),
            .optional("completed", type: .bool, description: "Filter by completion state. Omit to include completed and incomplete reminders."),
            .optional("due_from", type: .string, description: "Inclusive ISO 8601 lower bound for the due date."),
            .optional("due_to", type: .string, description: "Exclusive ISO 8601 upper bound for the due date."),
            .optional("limit", type: .int, description: "Maximum number of results. Omit to use 20; values are clamped to 1 through 100.")
        ]
    ) { input in
        try await NativeEventStore.shared.searchReminders(input)
    }

    static let readReminder = Tool<ReadReminderInput, ReminderOutput>(
        name: ToolNames.readReminder,
        description: "Read one reminder through EventKit by the reminder_id returned from reminders_search. This is read-only.",
        parameters: [
            .required("reminder_id", type: .string, description: "Stable reminder identifier returned by reminders_search.")
        ]
    ) { input in
        try await NativeEventStore.shared.readReminder(identifier: input.reminderID)
    }

    static let createReminder = Tool<CreateReminderInput, ReminderOutput>(
        name: ToolNames.createReminder,
        description: "Create a reminder through EventKit. This writes reminder data and requires confirmation before execution. It returns the saved reminder identifier and details.",
        parameters: [
            .required("title", type: .string, description: "Reminder title."),
            .optional("list", type: .string, description: "Exact reminder-list title. Omit to use the system default reminder list."),
            .optional("notes", type: .string, description: "Reminder notes."),
            .optional("due_at", type: .string, description: "ISO 8601 due date and time with a time zone."),
            .optional("priority", type: .int, description: "EventKit priority from 0 through 9, where 0 means no priority.")
        ]
    ) { input in
        try await NativeEventStore.shared.createReminder(input)
    }

    static let updateReminder = Tool<UpdateReminderInput, ReminderOutput>(
        name: ToolNames.updateReminder,
        description: "Update an existing reminder through EventKit. This writes reminder data and requires confirmation before execution. Omit fields that should remain unchanged.",
        parameters: [
            .required("reminder_id", type: .string, description: "Stable reminder identifier returned by reminders_search."),
            .optional("title", type: .string, description: "Replacement reminder title."),
            .optional("list", type: .string, description: "Exact destination reminder-list title."),
            .optional("notes", type: .string, description: "Replacement notes. Pass an empty string to clear them."),
            .optional("due_at", type: .string, description: "Replacement ISO 8601 due date and time. Pass an empty string to remove the due date."),
            .optional("priority", type: .int, description: "Replacement EventKit priority from 0 through 9."),
            .optional("completed", type: .bool, description: "Replacement completion state.")
        ]
    ) { input in
        try await NativeEventStore.shared.updateReminder(input)
    }
}

@MainActor
final class NativeEventStore {

    static let shared = NativeEventStore()

    private let store = EKEventStore()

    private init() {}

    func searchEvents(_ input: SearchCalendarInput) async throws -> [CalendarEventOutput] {
        try await requireAccess(to: .event)
        let startDate = try NativeDateParser.date(from: input.startAt)
        let endDate = try NativeDateParser.date(from: input.endAt)
        guard endDate > startDate else {
            throw NativeEventStoreError.invalidDateRange
        }
        let calendars = try matchingCalendars(
            title: input.calendar,
            entityType: .event)
        let predicate = store.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: calendars)
        let query = input.query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = min(max(input.limit ?? 20, 1), 100)

        return store.events(matching: predicate)
            .filter { event in
                guard let query, !query.isEmpty else { return true }
                return event.title.localizedCaseInsensitiveContains(query)
                    || event.location?.localizedCaseInsensitiveContains(query) == true
                    || event.notes?.localizedCaseInsensitiveContains(query) == true
            }
            .prefix(limit)
            .map(CalendarEventOutput.init)
    }

    func readEvent(identifier: String) async throws -> CalendarEventOutput {
        try await requireAccess(to: .event)
        guard let event = store.event(withIdentifier: identifier)
            ?? store.calendarItem(withIdentifier: identifier) as? EKEvent
        else {
            throw NativeEventStoreError.itemNotFound("Calendar event")
        }
        return CalendarEventOutput(event)
    }

    func createEvent(_ input: CreateCalendarEventInput) async throws -> CalendarEventOutput {
        try await requireAccess(to: .event)
        let startDate = try NativeDateParser.date(from: input.startAt)
        let endDate = try NativeDateParser.date(from: input.endAt)
        guard endDate > startDate else {
            throw NativeEventStoreError.invalidDateRange
        }

        let event = EKEvent(eventStore: store)
        event.title = input.title
        event.startDate = startDate
        event.endDate = endDate
        event.isAllDay = input.allDay ?? false
        event.location = input.location
        event.notes = input.notes
        event.calendar = try writableCalendar(
            title: input.calendar,
            entityType: .event)
        try store.save(event, span: .thisEvent, commit: true)
        return CalendarEventOutput(event)
    }

    func updateEvent(_ input: UpdateCalendarEventInput) async throws -> CalendarEventOutput {
        try await requireAccess(to: .event)
        guard input.hasChanges else {
            throw NativeEventStoreError.noChanges
        }
        if let span = input.span,
           span != "this_event" && span != "future_events"
        {
            throw NativeEventStoreError.invalidSpan
        }
        guard let event = store.event(withIdentifier: input.eventID)
            ?? store.calendarItem(withIdentifier: input.eventID) as? EKEvent
        else {
            throw NativeEventStoreError.itemNotFound("Calendar event")
        }

        guard let startDate = try input.startAt.map({
            try NativeDateParser.date(from: $0)
        }) ?? event.startDate,
        let endDate = try input.endAt.map({
            try NativeDateParser.date(from: $0)
        }) ?? event.endDate,
        endDate > startDate else {
            throw NativeEventStoreError.invalidDateRange
        }
        let destinationCalendar = try input.calendar.map {
            try writableCalendar(title: $0, entityType: .event)
        }

        if let title = input.title { event.title = title }
        event.startDate = startDate
        event.endDate = endDate
        if let allDay = input.allDay { event.isAllDay = allDay }
        if let location = input.location { event.location = location }
        if let notes = input.notes { event.notes = notes }
        if let destinationCalendar { event.calendar = destinationCalendar }

        let span: EKSpan = input.span == "future_events" ? .futureEvents : .thisEvent
        try store.save(event, span: span, commit: true)
        return CalendarEventOutput(event)
    }

    func searchReminders(_ input: SearchRemindersInput) async throws -> [ReminderOutput] {
        try await requireAccess(to: .reminder)
        let calendars = try matchingCalendars(
            title: input.list,
            entityType: .reminder)
        let predicate = store.predicateForReminders(in: calendars)
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
        let query = input.query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let dueFrom = try input.dueFrom.map {
            try NativeDateParser.date(from: $0)
        }
        let dueTo = try input.dueTo.map {
            try NativeDateParser.date(from: $0)
        }
        let limit = min(max(input.limit ?? 20, 1), 100)

        return reminders
            .filter { reminder in
                if let completed = input.completed,
                   reminder.isCompleted != completed
                {
                    return false
                }
                if let query, !query.isEmpty,
                   !reminder.title.localizedCaseInsensitiveContains(query),
                   reminder.notes?.localizedCaseInsensitiveContains(query) != true
                {
                    return false
                }
                let dueDate = reminder.dueDateComponents?.date
                if let dueFrom, dueDate == nil || dueDate! < dueFrom { return false }
                if let dueTo, dueDate == nil || dueDate! >= dueTo { return false }
                return true
            }
            .prefix(limit)
            .map(ReminderOutput.init)
    }

    func readReminder(identifier: String) async throws -> ReminderOutput {
        try await requireAccess(to: .reminder)
        guard let reminder = store.calendarItem(
            withIdentifier: identifier) as? EKReminder
        else {
            throw NativeEventStoreError.itemNotFound("Reminder")
        }
        return ReminderOutput(reminder)
    }

    func createReminder(_ input: CreateReminderInput) async throws -> ReminderOutput {
        try await requireAccess(to: .reminder)
        try validate(priority: input.priority)

        let reminder = EKReminder(eventStore: store)
        reminder.title = input.title
        reminder.notes = input.notes
        reminder.priority = input.priority ?? 0
        reminder.calendar = try writableCalendar(
            title: input.list,
            entityType: .reminder)
        if let dueAt = input.dueAt {
            reminder.dueDateComponents = dueDateComponents(
                from: try NativeDateParser.date(from: dueAt))
        }
        try store.save(reminder, commit: true)
        return ReminderOutput(reminder)
    }

    func updateReminder(_ input: UpdateReminderInput) async throws -> ReminderOutput {
        try await requireAccess(to: .reminder)
        guard input.hasChanges else {
            throw NativeEventStoreError.noChanges
        }
        try validate(priority: input.priority)
        guard let reminder = store.calendarItem(
            withIdentifier: input.reminderID) as? EKReminder
        else {
            throw NativeEventStoreError.itemNotFound("Reminder")
        }

        let destinationList = try input.list.map {
            try writableCalendar(title: $0, entityType: .reminder)
        }
        let replacementDueDateComponents: DateComponents?
        if let dueAt = input.dueAt {
            replacementDueDateComponents = dueAt.isEmpty
                ? nil
                : dueDateComponents(
                    from: try NativeDateParser.date(from: dueAt))
        } else {
            replacementDueDateComponents = nil
        }

        if let title = input.title { reminder.title = title }
        if let notes = input.notes { reminder.notes = notes }
        if let priority = input.priority { reminder.priority = priority }
        if let completed = input.completed {
            reminder.isCompleted = completed
            reminder.completionDate = completed ? Date() : nil
        }
        if let destinationList { reminder.calendar = destinationList }
        if input.dueAt != nil {
            reminder.dueDateComponents = replacementDueDateComponents
        }
        try store.save(reminder, commit: true)
        return ReminderOutput(reminder)
    }

    func requestAccess(to entityType: EKEntityType) async throws {
        let status = EKEventStore.authorizationStatus(for: entityType)
        if status == .fullAccess { return }
        if status == .denied || status == .restricted {
            throw NativeEventStoreError.permissionDenied(entityType)
        }

        let granted: Bool
        switch entityType {
        case .event:
            granted = try await store.requestFullAccessToEvents()
        case .reminder:
            granted = try await store.requestFullAccessToReminders()
        @unknown default:
            granted = false
        }
        guard granted else {
            throw NativeEventStoreError.permissionDenied(entityType)
        }
    }

    private func requireAccess(to entityType: EKEntityType) async throws {
        try await requestAccess(to: entityType)
    }

    private func matchingCalendars(
        title: String?,
        entityType: EKEntityType
    ) throws -> [EKCalendar]? {
        guard let title, !title.isEmpty else { return nil }
        let calendars = store.calendars(for: entityType).filter {
            $0.title == title
        }
        guard !calendars.isEmpty else {
            throw NativeEventStoreError.calendarNotFound(title)
        }
        return calendars
    }

    private func writableCalendar(
        title: String?,
        entityType: EKEntityType
    ) throws -> EKCalendar {
        if let calendar = try matchingCalendars(
            title: title,
            entityType: entityType)?.first
        {
            guard calendar.allowsContentModifications else {
                throw NativeEventStoreError.calendarReadOnly(calendar.title)
            }
            return calendar
        }

        let calendar: EKCalendar?
        switch entityType {
        case .event:
            calendar = store.defaultCalendarForNewEvents
        case .reminder:
            calendar = store.defaultCalendarForNewReminders()
        @unknown default:
            calendar = nil
        }
        guard let calendar else {
            throw NativeEventStoreError.defaultCalendarUnavailable
        }
        return calendar
    }

    private func dueDateComponents(from date: Date) -> DateComponents {
        Calendar.autoupdatingCurrent.dateComponents(
            in: TimeZone.autoupdatingCurrent,
            from: date)
    }

    private func validate(priority: Int?) throws {
        guard let priority else { return }
        guard (0...9).contains(priority) else {
            throw NativeEventStoreError.invalidPriority
        }
    }
}

private enum NativeDateParser {

    static func date(from value: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let standard = ISO8601DateFormatter()
        guard let date = standard.date(from: value) else {
            throw NativeEventStoreError.invalidDate(value)
        }
        return date
    }

    static func string(from date: Date?) -> String? {
        guard let date else { return nil }
        return ISO8601DateFormatter().string(from: date)
    }
}

enum NativeEventStoreError: LocalizedError {
    case calendarNotFound(String)
    case calendarReadOnly(String)
    case defaultCalendarUnavailable
    case invalidDate(String)
    case invalidDateRange
    case invalidPriority
    case invalidSpan
    case itemNotFound(String)
    case noChanges
    case permissionDenied(EKEntityType)

    var errorDescription: String? {
        switch self {
        case .calendarNotFound(let title):
            return "Calendar or reminder list `\(title)` was not found."
        case .calendarReadOnly(let title):
            return "Calendar or reminder list `\(title)` is read-only."
        case .defaultCalendarUnavailable:
            return "No default writable calendar or reminder list is available."
        case .invalidDate(let value):
            return "`\(value)` is not a valid ISO 8601 date with a time zone."
        case .invalidDateRange:
            return "The end date must be later than the start date."
        case .invalidPriority:
            return "Reminder priority must be between 0 and 9."
        case .invalidSpan:
            return "Calendar update span must be `this_event` or `future_events`."
        case .itemNotFound(let type):
            return "\(type) was not found. Refresh the search results before retrying."
        case .noChanges:
            return "No changes were provided."
        case .permissionDenied(let entityType):
            let category = entityType == .event ? "Calendars" : "Reminders"
            return "\(category) access was denied. Enable ModelCraft in System Settings > Privacy & Security > \(category). Do not retry this tool until the permission changes. retryable=false"
        }
    }
}

struct SearchCalendarInput: Codable {
    let startAt: String
    let endAt: String
    let query: String?
    let calendar: String?
    let limit: Int?

    enum CodingKeys: String, CodingKey {
        case startAt = "start_at"
        case endAt = "end_at"
        case query, calendar, limit
    }
}

struct ReadCalendarEventInput: Codable {
    let eventID: String

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
    }
}

struct CreateCalendarEventInput: Codable {
    let title: String
    let startAt: String
    let endAt: String
    let calendar: String?
    let allDay: Bool?
    let location: String?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case title, calendar, location, notes
        case startAt = "start_at"
        case endAt = "end_at"
        case allDay = "all_day"
    }
}

struct UpdateCalendarEventInput: Codable {
    let eventID: String
    let title: String?
    let startAt: String?
    let endAt: String?
    let calendar: String?
    let allDay: Bool?
    let location: String?
    let notes: String?
    let span: String?

    var hasChanges: Bool {
        title != nil || startAt != nil || endAt != nil || calendar != nil
            || allDay != nil || location != nil || notes != nil
    }

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case title, calendar, location, notes, span
        case startAt = "start_at"
        case endAt = "end_at"
        case allDay = "all_day"
    }
}

struct CalendarEventOutput: Codable {
    let eventID: String
    let title: String
    let startAt: String
    let endAt: String
    let calendar: String
    let allDay: Bool
    let location: String?
    let notes: String?
    let recurring: Bool

    init(_ event: EKEvent) {
        eventID = event.eventIdentifier ?? event.calendarItemIdentifier
        title = event.title
        startAt = NativeDateParser.string(from: event.startDate) ?? ""
        endAt = NativeDateParser.string(from: event.endDate) ?? ""
        calendar = event.calendar.title
        allDay = event.isAllDay
        location = event.location
        notes = event.notes
        recurring = event.hasRecurrenceRules
    }

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case title, calendar, location, notes, recurring
        case startAt = "start_at"
        case endAt = "end_at"
        case allDay = "all_day"
    }
}

struct SearchRemindersInput: Codable {
    let query: String?
    let list: String?
    let completed: Bool?
    let dueFrom: String?
    let dueTo: String?
    let limit: Int?

    enum CodingKeys: String, CodingKey {
        case query, list, completed, limit
        case dueFrom = "due_from"
        case dueTo = "due_to"
    }
}

struct ReadReminderInput: Codable {
    let reminderID: String

    enum CodingKeys: String, CodingKey {
        case reminderID = "reminder_id"
    }
}

struct CreateReminderInput: Codable {
    let title: String
    let list: String?
    let notes: String?
    let dueAt: String?
    let priority: Int?

    enum CodingKeys: String, CodingKey {
        case title, list, notes, priority
        case dueAt = "due_at"
    }
}

struct UpdateReminderInput: Codable {
    let reminderID: String
    let title: String?
    let list: String?
    let notes: String?
    let dueAt: String?
    let priority: Int?
    let completed: Bool?

    var hasChanges: Bool {
        title != nil || list != nil || notes != nil || dueAt != nil
            || priority != nil || completed != nil
    }

    enum CodingKeys: String, CodingKey {
        case reminderID = "reminder_id"
        case title, list, notes, priority, completed
        case dueAt = "due_at"
    }
}

struct ReminderOutput: Codable {
    let reminderID: String
    let title: String
    let list: String
    let notes: String?
    let dueAt: String?
    let priority: Int
    let completed: Bool
    let completionDate: String?

    init(_ reminder: EKReminder) {
        reminderID = reminder.calendarItemIdentifier
        title = reminder.title
        list = reminder.calendar.title
        notes = reminder.notes
        dueAt = NativeDateParser.string(from: reminder.dueDateComponents?.date)
        priority = reminder.priority
        completed = reminder.isCompleted
        completionDate = NativeDateParser.string(from: reminder.completionDate)
    }

    enum CodingKeys: String, CodingKey {
        case reminderID = "reminder_id"
        case title, list, notes, priority, completed
        case dueAt = "due_at"
        case completionDate = "completion_date"
    }
}

enum NativeApplication: String, CaseIterable, Sendable {
    case notes
    case mail

    var bundleIdentifier: String {
        switch self {
        case .notes: "com.apple.Notes"
        case .mail: "com.apple.mail"
        }
    }
}

enum AppToolError: LocalizedError {
    case noChanges

    var errorDescription: String? {
        "No changes were provided."
    }
}

private enum NotesHTML {

    static func body(fromPlainText value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}

struct SearchNotesInput: Codable {
    let query: String
    let folder: String?
    let limit: Int?
}

struct ReadNoteInput: Codable {
    let noteID: String

    enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
    }
}

struct CreateNoteInput: Codable {
    let title: String
    let body: String
    let folder: String?
}

struct UpdateNoteInput: Codable {
    let noteID: String
    let title: String?
    let body: String?

    enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
        case title, body
    }
}

struct NoteSummary: Codable {
    let noteID: String
    let title: String
    let folder: String
    let modificationDate: String
    let excerpt: String

    enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
        case title, folder, excerpt
        case modificationDate = "modification_date"
    }
}

struct NoteDetail: Codable {
    let noteID: String
    let title: String
    let folder: String
    let content: String
    let creationDate: String
    let modificationDate: String
    let passwordProtected: Bool

    enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
        case title, folder, content
        case creationDate = "creation_date"
        case modificationDate = "modification_date"
        case passwordProtected = "password_protected"
    }
}

struct NoteMutationResult: Codable {
    let noteID: String
    let title: String
    let folder: String

    enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
        case title, folder
    }
}

struct SearchMailInput: Codable {
    let query: String
    let account: String?
    let mailbox: String?
    let unreadOnly: Bool?
    let limit: Int?

    enum CodingKeys: String, CodingKey {
        case query, account, mailbox, limit
        case unreadOnly = "unread_only"
    }
}

struct ReadMailInput: Codable {
    let messageID: String
    let account: String
    let mailbox: String
    let maxContentLength: Int?

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case account, mailbox
        case maxContentLength = "max_content_length"
    }
}

struct CreateMailDraftInput: Codable {
    let to: [String]
    let cc: [String]?
    let bcc: [String]?
    let subject: String
    let body: String
}

struct MailSummary: Codable {
    let messageID: String
    let subject: String
    let sender: String
    let dateReceived: String
    let account: String
    let mailbox: String
    let unread: Bool
    let excerpt: String

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case subject, sender, account, mailbox, unread, excerpt
        case dateReceived = "date_received"
    }
}

struct MailDetail: Codable {
    let messageID: String
    let subject: String
    let sender: String
    let dateReceived: String
    let account: String
    let mailbox: String
    let read: Bool
    let internetMessageID: String
    let content: String

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case subject, sender, account, mailbox, read, content
        case dateReceived = "date_received"
        case internetMessageID = "internet_message_id"
    }
}

struct MailDraftResult: Codable {
    let draftID: String
    let subject: String
    let sent: Bool

    enum CodingKeys: String, CodingKey {
        case draftID = "draft_id"
        case subject, sent
    }
}

struct RunAppleScriptInput: Codable {
    let script: String
    let targetAppBundleID: String

    enum CodingKeys: String, CodingKey {
        case script
        case targetAppBundleID = "target_app_bundle_id"
    }
}

struct RunAppleScriptOutput: Codable {
    let result: String
}
