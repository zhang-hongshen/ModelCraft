# Settings

This document maps the Settings window to its stored values and the code that consumes them. Read it before adding a setting, renaming a `UserDefaults` key, or changing a Settings tab. Behavior behind each setting is owned by the linked feature document.

## Storage contract

Settings are stored in `UserDefaults.standard` under the keys declared in `UserDefaults+.swift`; defaults live in `UserDefaultSettings`. `UserSettings` is the observable editor used by Settings views and writes each value back in `didSet`. Shortcuts are the exception: `KeyboardShortcuts.Recorder` edits the package's own `UserDefaults` values directly.

Several consumers read `UserDefaults` directly instead of observing `UserSettings`, because they run outside the view hierarchy: the media tools, `ToolDefinition`, `SkillManager`, `HolidayStore`, `Scheduler`, `QuickEntry`, `AgentExecutor`, and `SettingsModifier` and `ChatView` (through `@AppStorage`). `settings_update` changes the General settings through `UserSettings.shared`, the instance the app puts in the environment, so the Settings window shows its changes; a setting it should offer is added to that tool's schema as well (see [Tools](tools.md#operating-modelcraft)). A key therefore is a persisted contract. Renaming one, or changing its value type, abandons the user's stored value unless a migration is added.

## Tabs

| Tab | Setting | Key | Consumer | Owner doc |
| --- | --- | --- | --- | --- |
| General | Appearance | `appearance` | `SettingsModifier.preferredColorScheme` | [Design](../design.md) |
| General | Language | `language` | `SettingsModifier` sets `\.locale` | [Design](../design.md) |
| Notifications | Notify when scheduled tasks finish | `notifyWhenScheduledTasksFinish` | `Scheduler` | [Scheduled tasks](schedules.md#runs) |
| Shortcuts | Voice input shortcut | `KeyboardShortcuts_voiceInput` (legacy: `voiceInputHotKey`) | `ChatView` and `QuickEntryView` (package event streams while key) | [Voice input](voice-input.md#hot-key) |
| Shortcuts | Quick Entry shortcut | `KeyboardShortcuts_quickEntry` (legacy: `quickEntryHotKey`) | `QuickEntry` (package key-down handler) | [Quick Entry](quick-entry.md#shortcut) |
| General | Import from (Claude Code, Codex, WorkBuddy) | none (an action) | `SessionImportView` | [Chat](chat.md#importing-agent-sessions) |
| General | Load tools when needed | `loadToolsWhenNeeded` | `ToolDefinition.allToolSchema(for:)` | [Tools](tools.md#tool-set-and-on-demand-loading) |
| Models | Image generation model | `imageGenerationModelID` | `ImageTool.allTools` | [Media generation](media-generation.md) |
| Models | Video generation model | `videoGenerationModelID` | `VideoTool` schema and evaluator choice | [Media generation](media-generation.md) |
| Storage | Skill directories | `customSkillDirectories` | `SkillManager.loadSkills` | [Tools](tools.md#skill-discovery) |
| Chat composer | Permission mode | `toolPermissionMode` | `AgentExecutor.executeToolCall` | [Tools](tools.md#permission-modes) |
| Scheduled Tasks page > Workdays | Holiday region | `holidayRegion` | `HolidayStore` | [Scheduled tasks](schedules.md#workdays) |
| Permissions | macOS privacy states | none (read from the system) | — | [Computer use](computer-use.md#permissions) |

## Adding a setting

1. Declare the key in `UserDefaults` and its default in `UserDefaultSettings`.
2. Add an observable property to `UserSettings` that reads the stored value with the default and writes it in `didSet`.
3. Present it in the owning tab using a grouped `Form` row that follows [Design](../design.md).
4. Read it from the owning feature, and document the behavior in that feature's document rather than here.
