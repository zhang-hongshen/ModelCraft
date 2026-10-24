# Computer use

This document owns GUI control of other applications: semantic accessibility tools, coordinate screen tools, their shared state, and the macOS permissions they need. Read it before changing `ComputerUseTool`, `ScreenControlTool`, `UIManager`, `ScreenControlManager`, `AXUIElement+`, or Settings > Permissions.

Typed Notes, Reminders, Calendar, and Mail tools and the AppleScript fallback are described in [Tools](tools.md#tool-set-and-on-demand-loading). Approval rules for these tools are in [Tools](tools.md#execution-approval). GUI control is the fallback when no typed tool covers an operation.

## Tool layers

| Layer | Tools | Implementation | Permission |
| --- | --- | --- | --- |
| Discovery | `list_running_application` | `NSWorkspace` running applications | None |
| Semantic UI | `get_ui_hierarchy`, `click_element`, `type_text`, `press_key` | `UIManager` over the Accessibility API (`AXUIElement`) | Accessibility |
| Visual capture | `capture_full_screen`, `capture_app_window` | `ScreenControlManager` with ScreenCaptureKit | Screen Recording |
| Coordinates | `move`, `click`, `drag`, `scroll` | `ScreenControlManager` with `CGEvent` in global screen points | Accessibility |

Prefer the semantic layer: it acts on named elements and does not depend on window position. Coordinate tools are for interfaces whose accessibility tree is incomplete.

## Element indexes

`get_ui_hierarchy` walks every visible window of the target application, up to `maxDepth` (default 30), and returns one line per element. Interactive elements receive a numeric index and list their advertised actions; context elements carry text and structure only.

`UIManager` caches the interactive elements per bundle identifier (at most five applications) and replaces the cache on every hierarchy call. `click_element` and `type_text` resolve the index against that cache, so an index is valid only for the most recent hierarchy of that application. Any UI change can make it stale; the schemas tell the model to inspect again after acting.

`type_text` replaces the full value of an editable element. `press_key` sends a virtual key code with optional `command`, `shift`, `option`, and `control` modifiers. Target applications are located by bundle identifier, then by localized name, and activated before the action.

## Captures and coordinates

`capture_full_screen` returns one image of all displays; `capture_app_window` returns one image per visible window with its global frame. Both describe coordinates in global screen points, which the coordinate tools consume directly. The images are stored as `image` blocks in the tool result, which drive the UI; `LMService.append` attaches them to the model-facing tool message, so a vision model sees the captured pixels alongside the coordinate text in `content`.

## Permissions

The app is not sandboxed. It runs with the hardened runtime and declares the Apple Events automation entitlement and the Calendars entitlement (`com.apple.security.personal-information.calendars`), which EventKit requires for both Calendar and Reminders access; without it the system denies access without prompting. Accessibility and Screen Recording are granted by the user in System Settings:

- Semantic tools check `AXIsProcessTrustedWithOptions` with the prompt option, so macOS shows the Accessibility request the first time one runs.
- Settings > Permissions shows the state of Calendars, Reminders, Notes and Mail automation, Accessibility, and Screen Recording, requests EventKit access, and opens the matching System Settings pane for the rest. States refresh when the view appears.

A missing permission is a tool failure that the model can explain to the user. It is separate from ModelCraft's own per-conversation approval prompt.
