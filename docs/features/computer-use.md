# Computer use

This document owns GUI control of other applications: semantic accessibility tools, coordinate screen tools, their shared state, and the macOS permissions they need. Read it before changing `ComputerUseTool`, `ScreenControlTool`, `UIManager`, `ScreenControlManager`, `VirtualCursor`, `AXUIElement+`, or Settings > Permissions.

Typed Notes, Reminders, Calendar, and Mail tools and the AppleScript fallback are described in [Tools](tools.md#tool-set-and-on-demand-loading). Approval rules for these tools are in [Tools](tools.md#execution-approval). GUI control is the fallback when no typed tool covers an operation.

## Tools

Every tool names its target with `app`, which accepts a name as `list_apps` shows it, a bundle identifier, or the bundle's file name (so `Safari` matches on a system where its localized name differs). `ComputerUseTool.resolveApp` brings a running application to the front, waiting briefly so keyboard events reach it, or opens an installed one from the standard application folders.

| Tool | Purpose | Implementation | Permission |
| --- | --- | --- | --- |
| `list_apps`, `open_app` | Discover and open applications | `NSWorkspace` | None |
| `app_find` | List or search accessibility elements | `UIManager` over `AXUIElement` | Accessibility |
| `app_screenshot`, `app_zoom` | See an application or the screen | `ScreenControlManager` with ScreenCaptureKit | Screen Recording |
| `app_click`, `app_type`, `app_key`, `app_scroll`, `app_drag` | Act on an element index or screenshot pixel | `ScreenControlManager` virtual pointer and `CGEvent` | Accessibility |
| `app_menu` | Choose a menu bar command by its title path | `AXMenuBar` items pressed through Accessibility | Accessibility |

`app_click` and `app_scroll` take either an `element` from `app_find` or `x`/`y` from `app_screenshot`; `app_type` takes an optional element and otherwise types at the keyboard focus. A plain left click on an element uses its `AXPress` action, which works on covered windows; any other click is posted at the element's center. `app_key` takes key names joined with `+` (`cmd+shift+t`, `return`) and maps them to ANSI virtual key codes. `app_menu` matches titles ignoring case and treats `...` as `…`; when a title is missing, the error lists the titles at that level.

## Element indexes

`app_find` walks every visible window and the menu bar of the target application, up to `max_depth` (default 30), and returns one line per element. Interactive elements receive a numeric index and list their advertised actions; context elements carry text and structure only. With `query`, only lines containing every query word (ignoring case) are returned; the index cache still covers the whole tree.

`UIManager` caches the interactive elements per bundle identifier (at most five applications) and replaces the cache on every `app_find` call. Actions resolve `element` against that cache, so an index is valid only for the most recent `app_find` of that application. Any UI change can make it stale; the schemas tell the model to look again after acting.

`app_type` with `replace` sets `AXValue` directly when the element allows it; otherwise it focuses the element (clicking its center when focus cannot be set), sends Command-A, and types. Typing posts Unicode keyboard events, with line breaks and tabs sent as Return and Tab.

## Screenshots and coordinates

`app_screenshot` with `app` captures only that application's on-screen windows (including its menus and sheets) on the display that shows most of its largest window, cropped to their union; without `app` it captures all displays. Images are scaled so the longer side is at most 1280 pixels (`ScreenControlManager.maxScreenshotEdge`), since vision models resize larger images themselves and lose coordinate precision, and are encoded as JPEG.

Coordinates are pixels of the screenshot as the model saw it. Each capture records a `ScreenshotFrame` (origin in global screen points and pixels-per-point scale) under the application's process identifier, or 0 for all displays; `app_click`, `app_scroll`, `app_drag`, and `app_zoom` map pixels back through the frame of the latest screenshot taken with the same `app`. A pixel outside that image, or no screenshot at all, is a failed result telling the model what to do. Frames are kept in memory only, so they go stale when windows move and do not survive a relaunch.

`app_zoom` captures a rectangle of the latest screenshot at up to the display's native pixel density for reading small text. It records no frame: coordinates always refer to the `app_screenshot`. Each image is saved as a JPEG in the chat's folder, like generated media, and returned as an image `resource_link` block; `LMService.append` attaches it to the model-facing tool message, so a vision model sees the pixels alongside the text in `content`. The chat shows it as a small thumbnail beside the tool row; clicking it opens the file in the file inspector, and its context menu offers Copy and Show in Finder.

## Virtual pointer

Mouse actions never move the user's cursor. `ScreenControlManager` keeps its own pointer location, which `app_click`, `app_scroll`, and `app_drag` update. Each action finds the front-most on-screen window containing the point, then posts the mouse events with `CGEvent.postToPid` to that window's process, tagged with its window number. Clicks carry the button, a running click count for double and triple clicks, and modifier flags. Clicks and drags activate the owning application first, as a physical click would, so later keyboard events reach it. Keyboard events go through the HID event tap and follow the active application, which is why `app_type` and `app_key` require `app`.

`VirtualCursor` draws the pointer as a click-through overlay panel that animates to each target and hides after three seconds of inactivity. Captures exclude it, and hit-testing skips it.

Some applications, notably Chromium- and Electron-based ones, may ignore mouse events that do not come from the window server; use element actions or `app_menu` for those.

## Approval

`app_click`, `app_drag`, `app_type`, `app_key`, and `app_menu` require approval; discovery, `app_find`, screenshots, zoom, and scrolling do not. **Always Allow** authorizes further actions in the same application, keyed by the lowercased `app` argument, so naming the same application differently asks again. Coordinate actions without `app` share one authorization for any window on screen. The stored fields of `ToolAuthorizationContext` are unchanged.

## Permissions

The app is not sandboxed. It runs with the hardened runtime and declares the Apple Events automation entitlement and the Calendars entitlement (`com.apple.security.personal-information.calendars`), which EventKit requires for both Calendar and Reminders access; without it the system denies access without prompting. Accessibility and Screen Recording are granted by the user in System Settings:

- `app_find` and the action tools check `AXIsProcessTrustedWithOptions` with the prompt option, so macOS shows the Accessibility request the first time one runs.
- `app_screenshot` and `app_zoom` check `CGPreflightScreenCaptureAccess` and call `CGRequestScreenCaptureAccess` when it is missing, then fail with a result that names the System Settings pane.
- Settings > Permissions shows the state of Calendars, Reminders, Notes and Mail automation, Accessibility, and Screen Recording, requests EventKit access, and opens the matching System Settings pane for the rest. States refresh when the view appears.

A missing permission is a tool failure that the model can explain to the user. It is separate from ModelCraft's own per-conversation approval prompt.
