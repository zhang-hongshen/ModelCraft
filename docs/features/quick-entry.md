# Quick Entry

This document owns Quick Entry: the system-wide shortcut, the panel, reading the user's current context, and how a request becomes a new chat. Read it before changing `QuickEntry`, `QuickEntryView`, `QuickEntryContext`, or shortcut handling.

## Components

| Owner | Responsibility |
| --- | --- |
| `QuickEntry` | Created once in `ModelCraftApp` and started by the main window's first `.task`. Registers the shortcut, owns the panel, places it, and hands a submitted request to the main window. |
| `KeyboardShortcuts` / `Shortcuts.swift` | Records, persists, and registers the named global shortcut, including changes made in Settings. |
| `QuickEntryView` | The request field, voice input through the shared `STTService`, and the captured context as removable items. |
| `QuickEntryContext` | Reads the context from the app that was active and writes the message that is sent. |

## Shortcut

Settings > Shortcuts uses `KeyboardShortcuts.Recorder` for Quick Entry. The named shortcut is `quickEntry`, stored by the package under `KeyboardShortcuts_quickEntry`; its initial combination is ⌥Space. A legacy `quickEntryHotKey` combination supplies the initial value when no package setting exists. Later package settings, including a cleared shortcut, take precedence; legacy keys remain untouched.

`QuickEntry.start` installs one `KeyboardShortcuts.onKeyDown` handler. The package updates registration when the user changes or clears the shortcut and suspends it while recording. The shortcut is global, consumes the combination, and needs no Accessibility permission. Pressing it while the panel is open closes it.

## Panel

The panel is a borderless, non-activating `NSPanel` at the floating level, on every Space and over full-screen apps. It does not activate ModelCraft, so the app the user was in stays frontmost while its context is read and the main window does not come forward. It is centred horizontally on the screen under the pointer, with its top a fifth of the way down, and keeps that top edge while its height follows the content.

Each opening hosts a new `QuickEntryView`, so the request and context start empty. Escape (or Escape during a recording, which cancels the recording first), the shortcut, or the panel losing key status closes it; closing releases the view, which cancels a recording and a capture still in progress. A macOS permission prompt takes key status too, so the first use that triggers one closes the panel.

Voice input follows [Voice input](voice-input.md): the microphone button or the voice input shortcut records, replacing the locked request field with the microphone waveform. Pause stops capture and starts transcription; the result is appended to the request, editing resumes, and Send replaces the microphone. Nothing is sent automatically.

## Context

Before presenting the panel, `QuickEntryContext.selection(from:)` snapshots the selected text and the image under the pointer through Accessibility. This preserves the source app's focus and unobscured hit target. `QuickEntryContext.capture(from:selection:)` then reads Finder or browser context asynchronously, unless ModelCraft itself was active:

| Active app | Context | Source |
| --- | --- | --- |
| Finder | The selected items, or the front window's folder when nothing is selected | AppleScript |
| Safari, Chrome, Edge, Brave, Arc | The front tab's title and URL | AppleScript |
| Any app other than Finder | The focused element's selected text | Accessibility (`kAXSelectedTextAttribute`), only when already trusted |
| Any app | The HTTP(S) URL and description of the image under the pointer, when exposed | Accessibility hit testing and `kAXURLAttribute`, only when already trusted |

Anything the app does not offer, or the user has not allowed, is left out without an error. AppleScript needs the Automation permission for that app, which macOS asks for on first use.

Context is read on invocation, without a persistent mouse or selection monitor. Clicking a web image does not necessarily select it; image hit testing uses the pointer's position immediately before the panel opens. An image URL is a reference, not a downloaded image attachment. Users can paste an image or drop a local image into the panel to attach its actual pixels. These images are encoded as uniquely named PNG files in `Message.draftDirectory`, shown as removable thumbnails, and deleted when removed or when the panel is dismissed without submitting. Submitting transfers ownership to the normal chat attachment path.

## Sending

Return sends a non-empty request once context capture finishes. `QuickEntryContext.message(for:)` writes the request followed by a section for each remaining context item: file paths as a list, the page and pointed image as links, and selected text as a quote. Finder files are listed by path, not attached; the agent works on the originals with the file tools under the usual permission mode. Pasted or dropped images are sent as attachments and moved into the chat folder (see [Chat](chat.md#data-model)).

`QuickEntry` closes the panel, calls `GlobalStore.startNewChat()`, sets `GlobalStore.newChatPrompt` with a single `ChatRequest` containing text and image files, activates the app, and brings forward the main window (the one whose identifier starts with `ModelCraftApp.mainWindowID`), opening one when none exists. `ChatView` consumes the request once and sends it through the normal request path, so approvals and questions appear in that window. If it cannot submit yet, it retains both the text and the attachments in the composer.
