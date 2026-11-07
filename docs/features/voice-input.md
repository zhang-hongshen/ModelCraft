# Voice input

This document owns dictation into the chat composer: recording, speech recognition, insertion into the draft, and the voice input hot key. Read it before changing voice handling in `ChatView`, `STTService`, `AudioRecorder`, or shortcut handling.

Voice input only fills the draft. The user reviews and sends it like typed text through the normal request path described in [Chat](chat.md); nothing is sent or spoken automatically.

## Components

| Owner | Responsibility |
| --- | --- |
| `ChatView.startVoiceInput` / `toggleVoiceInput` / `cancelVoiceInput` | Runs one recording in `voiceInputTask` and inserts its transcript into the draft. |
| `STTService` | Records until `stop()`, then transcribes with the cached `mlx-community/whisper-large-v3-turbo-4bit` runtime owned by its private `VoiceRecognizer` actor. Its `State` is `idle`, `loading`, `recording`, or `transcribing`. |
| `AudioRecorder` | Owns an `AVAudioEngine` input tap, converts microphone audio to 16 kHz mono, and buffers samples and the current level behind a lock. |
| `KeyboardShortcuts` / `Shortcuts.swift` | Shortcut recording, persistence, legacy combination migration, and events observed while the input window is key. |
| `VoiceLevelView` | A scrolling microphone waveform while recording, and progress while preparing or transcribing. |

`STTService` is an app-wide environment object created in `ModelCraftApp`. The dictation model loads on the first transcription from the [shared model cache](models.md#storage-layout) through `HubCache.loadModel`, which downloads the snapshot when the local copy is missing or fails to load.

## Flow

1. An empty draft shows the microphone action; a draft with text or attachments shows Send. The microphone or shortcut starts `STTService.record()` immediately, without waiting for model loading.
2. Recording replaces the editor with Cancel (Escape) and a waveform. Typing and sending are blocked during preparation, recording, and transcription; the draft and cursor are retained. The waveform samples microphone power at 30 Hz, follows speech with a fast attack and slower release, and settles to a static baseline in silence. Reduce Motion shows a level meter without scrolling.
3. Pause, or the shortcut again, stops recording. Capture is frozen before local transcription begins, and the capsule shows transcription progress. Pause is disabled outside the recording state.
4. A non-empty result is inserted at the draft cursor. Editing resumes and Send replaces the microphone; an empty result returns to the previous draft state. Quick Entry uses the same recording UI and appends the transcript to its request.

Cancel and leaving the view cancel the owning task and release the microphone immediately. The task remains owned until inference settles, and cancellation is checked before inserting text. Changing chats or receiving an agent approval/user-input request also cancels chat dictation. Other failures, including denied microphone access or a model that fails to load, are shown in the "Voice Input Failed" alert (inline in Quick Entry).

## Speech recognition

Dictation uses Whisper Turbo with automatic language detection, temperature zero, and 30-second windows. No language is explicitly specified, so input is not constrained to Chinese or another fixed language. Synchronous MLX inference stays on the `VoiceRecognizer` actor; cancellation is checked between windows. Recognition produces the original transcript without a language-model cleanup or rewrite pass. Microphone power only drives the display and never gates captured audio.

The existing `STTService.loadModel(id:)` Qwen3-ASR loader remains available to audio-file content extraction; it is separate from microphone dictation.

## Hot key

Settings > Shortcuts uses `KeyboardShortcuts.Recorder` for voice input. The named shortcut is `voiceInput`, stored by the package under `KeyboardShortcuts_voiceInput`; its initial combination is ⌃⌥Space. On first use, a legacy `voiceInputHotKey` combination supplies the initial value instead. Package settings, including an explicitly cleared shortcut, take precedence thereafter. Legacy keys remain untouched. Modifier-only shortcuts such as fn cannot be recorded or registered by the package and use the initial default instead.

`ChatView` and `QuickEntryView` observe `KeyboardShortcuts.events(.keyDown, for: .voiceInput)` only while their window is key. Losing key status or leaving the view cancels the stream and releases its registration. Other apps and Settings do not trigger dictation. The package suspends shortcuts while its recorder is active.

## Platform requirements

Voice input needs microphone permission (`NSMicrophoneUsageDescription` and the audio-input entitlement).
