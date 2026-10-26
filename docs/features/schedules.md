# Scheduled tasks

This document owns scheduled tasks: the `Schedule` model and its recurrence rule, workday and holiday resolution, the run lifecycle, unattended execution, the schedule tools, and the Scheduled Tasks page. Read it before changing `Schedule`, `ScheduleRule`, `WorkdayCalendar`, `HolidayStore`, `Scheduler`, `ScheduleTool`, or `Features/Schedule/`.

## Model

A `Schedule` (SwiftData) holds a name, the prompt sent at each run, the model ID, an optional project, `isEnabled`, and a `ScheduleRule`. The rule is stored encoded in `ruleData` because SwiftData composite attributes do not reliably hold enums. Chats created by runs point back through `Chat.schedule` (nullified when either side is deleted); deleting a project deletes its schedules.

`checkpoint` is the single due-time anchor. A schedule is due when `rule.nextRun(after: checkpoint)` is at or before now. The checkpoint moves to now on every run attempt, every edit, and every enable, so:

- occurrences missed while the app was closed or the task was paused collapse into one run, or none when paused;
- an edit never fires occurrences from before it;
- the next run is always derived, never stored, so holiday data and exceptions apply as soon as they change.

## Recurrence rule

`ScheduleRule.validated()` is the only constructor path used by the editor and tools; it rejects field combinations that do not apply to the frequency and fills omitted day lists from `start`.

- `frequency`: `once`, `hourly`, `daily`, `weekly`, `monthly`, `yearly`, repeated every `interval` units counted from the period containing `start`.
- Time of day comes from `start`; hourly runs step from `start` in fixed hours.
- Days: `weekdays` (weekly), `monthDays` with `-1` for the last day (monthly, yearly; a day a month lacks is skipped), `months` (yearly).
- `workdayPosition` replaces the day lists with the Nth workday (negative counts from the end) of each week, month, or listed month.
- `workdays` decides what happens to a named day that is not a workday: `any` keeps it, `only` skips it, `next`/`previous` move it to the neighboring workday. Hourly accepts `any` and `only`.
- `end` stops the rule.

Occurrence search is bounded; a rule that names no day within the bound has no next run.

## Workdays

`WorkdayCalendar` is a value that decides a day in this order: the user's `WorkdayException` for that day, then the holiday region's `SpecialDay`, then `Calendar.isDateInWeekend` for the user's locale. Holidays can therefore make a weekday a day off, and makeup workdays (调休) make a weekend day a workday.

`HolidayStore` owns the holiday region (`holidayRegion`, default the locale's region, empty for none) and the loaded holidays. `refresh()` loads this year and next year once each, from the on-disk cache in `Application Support/<bundle ID>/Holidays/<region>-<year>.json` or from the network:

- `CN` uses the State Council schedule from `NateScarlet/holiday-cn` via jsDelivr, which includes makeup workdays;
- other regions use Nager.Date nationwide public holidays (`global` and type `Public`), which have no makeup workdays.

A year that is not published or cannot be fetched is listed in `unavailableYears`, follows the weekend only, and is retried on the next refresh. The scheduler refreshes once a day, and the Workdays sheet refreshes when it opens.

## Runs

`Scheduler`, owned by `ModelCraftApp` and started from the window's launch task, checks enabled schedules at least every 30 seconds and sleeps until the next due run when it is sooner. It holds a `ProcessInfo` activity while any schedule is enabled so App Nap does not delay checks; idle system sleep still happens. Runs happen only while the app is open.

A run creates a chat titled with the schedule name in the schedule's project, linked to the schedule, and sends the prompt through a dedicated `ChatService(isUnattended: true)`. A schedule never overlaps itself: a run that comes due while the previous one is still going is dropped. A missing model or a failed request is recorded in `lastError`; a successful or stopped run clears it.

When **Notify when scheduled tasks finish** (`notifyWhenScheduledTasksFinish`, off by default) is on, a completed run posts a notification with the start of the reply and a failed run posts its error; a stopped run posts nothing. The setting is read when the run finishes. Turning it on in Settings > General is when macOS asks for notification permission, and the row points to System Settings when permission is denied. `Scheduler` is the `UNUserNotificationCenter` delegate: notifications also show while the app is in front, and clicking one selects the run's chat through `GlobalStore` and activates the app; it does not reopen a window the user closed.

In an unattended run `AgentExecutor` returns a failed tool result instead of waiting: `request_user_input` tells the model to continue with stated assumptions, and any call that needs approval and is not already authorized is refused with a message to describe the action instead. Stopping a run from the Scheduled Tasks page cancels the scheduler's service; the chat view's own stop button does not reach it.

## Tools

`ScheduleTool` defines deferred tools: `schedule_create`, `schedule_list`, `schedule_update`, `schedule_delete`, `workdays_list`, and `workdays_set`. Create, update, delete, and `workdays_set` require approval, so they are refused inside unattended runs. `schedule_create` is built per call with the chat's project and model (`ToolExecutor.dispatch(_:projectID:modelID:)`). Weekday names in arguments and results are English regardless of the user's language, and returned times are ISO 8601 with the local offset followed by the weekday so the model can check them against the request. A rule field in `schedule_update` replaces the whole rule, requiring `frequency` and `start_at`.

## UI

`SchedulesView` (sidebar: Scheduled Tasks) lists schedules with their rule, next run, last error, enable switch, Run Now/Stop, and recent run chats. `ScheduleEditor` edits every rule field and previews the next five runs with the current workday calendar. `WorkdaysView` chooses the holiday region, lists holidays, makeup workdays, and exceptions for the coming months, and edits exceptions.
