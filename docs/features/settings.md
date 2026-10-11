# Settings

This document maps the Settings window to its stored values and the code that consumes them. Read it before adding a setting, renaming a `UserDefaults` key, or changing a Settings tab. Behavior behind each setting is owned by the linked feature document.

## Storage contract

Settings are stored in `UserDefaults.standard` under the keys declared in `UserDefaults+.swift`; defaults live in `UserDefaultSettings`. `UserSettings` is the observable editor used by Settings views and writes each value back in `didSet`.

Several consumers read `UserDefaults` directly instead of observing `UserSettings`, because they run outside the view hierarchy: `HubApi.downloadBaseDirectory`, the media tools, `SkillManager`, and `SettingsModifier` (through `@AppStorage`). A key therefore is a persisted contract. Renaming one, or changing its value type, abandons the user's stored value unless a migration is added.

## Tabs

| Tab | Setting | Key | Consumer | Owner doc |
| --- | --- | --- | --- | --- |
| General | Appearance | `appearance` | `SettingsModifier.preferredColorScheme` | [Design](../design.md) |
| General | Language | `language` | `SettingsModifier` sets `\.locale` | [Design](../design.md) |
| Models | Image generation model | `imageGenerationModelID` | `ImageTool.allTools` | [Media generation](media-generation.md) |
| Models | Video generation model | `videoGenerationModelID` | `VideoTool` schema and evaluator choice | [Media generation](media-generation.md) |
| Storage | Model download location | `modelDownloadBaseDirectory` | `HubApi.default`, `LocalModelStore` | [Language models](models.md#storage-layout) |
| Storage | Image, video, audio output folders | `imageOutputDirectory`, `videoOutputDirectory`, `audioOutputDirectory` | Media tools | [Media generation](media-generation.md) |
| Storage | Skill directories | `customSkillDirectories` | `SkillManager.loadSkills` | [Tools](tools.md#skill-discovery) |
| Permissions | macOS privacy states | none (read from the system) | — | [Computer use](computer-use.md#permissions) |

## Adding a setting

1. Declare the key in `UserDefaults` and its default in `UserDefaultSettings`.
2. Add an observable property to `UserSettings` that reads the stored value with the default and writes it in `didSet`.
3. Present it in the owning tab using a grouped `Form` row that follows [Design](../design.md).
4. Read it from the owning feature, and document the behavior in that feature's document rather than here.
