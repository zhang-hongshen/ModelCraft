# Voice mode

This document owns spoken conversation: the listen-send-speak loop, interruption, speech recognition, speech synthesis, and the shared audio engine. Read it before changing voice handling in `ChatView`, `STTService`, `TTSService`, `VoiceAudioEngine`, or `AudioRecorder`.

Voice mode is an input and output layer over the normal chat request path described in [Chat](chat.md). It does not create a separate conversation, prompt, or persistence path.

## Components

| Owner | Responsibility |
| --- | --- |
| `ChatView.startVoiceMode` / `stopVoiceMode` | Runs the loop and its `VoiceState` (`idle`, `loading`, `listening`, `responding`). |
| `STTService` | Loads `mlx-community/Qwen3-ASR-0.6B-4bit` and transcribes one utterance per `listen()` call with streaming inference. |
| `TTSService` | Loads `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit` and speaks streamed assistant text sentence by sentence. |
| `VoiceAudioEngine.shared` | One full-duplex `AVAudioEngine` with voice processing for both microphone capture (16 kHz mono) and playback. |
| `AudioRecorder` | Buffers captured samples behind a lock and exposes the current audio level to `STTService`. |
| `ChatView.swift` voice views | `VoicePhase` and the composer's level bars, `VoiceLevelView`. |

`STTService` and `TTSService` are app-wide environment objects created in `ModelCraftApp`. Both models load lazily on the first voice session from `HubApi.system` (`<base>/.system/models`) through `HubApi.loadModel`, which downloads the snapshot when the local copy is missing or fails to load.

## Loop

1. Load both models, then start listening.
2. `listen()` waits until the level stays above the speech threshold for 300 ms, keeps 0.5 s of pre-roll so the first syllable is transcribed, and ends the utterance after 1 s of silence.
3. A non-empty transcript is sent, prefixed with any text typed in the composer and together with the composer's files, which are then cleared. It is sent with `ChatService.sendMessage`, like typed input, to the open chat or a new one created by `ChatView.openChat`. The loop keeps that chat for later turns.
4. While the response streams, `ChatView` feeds the latest assistant content to `TTSService.feed`; complete sentences are queued for synthesis. After the turn completes, every assistant reply in it is fed once more with `isComplete: true` so trailing text is spoken.
5. The next `listen()` starts as an `async let` as soon as the response begins, so the user can speak at any time.

## Composer

Voice mode keeps the composer so files and text can still be added, and changes its appearance instead:

- The top of the composer shows the live transcript of the utterance being recorded (`STTService.transcript`, confirmed plus provisional text). Generation progress stays in the conversation.
- `VoiceControls` replaces the send button with `VoiceLevelView`, a mute toggle (`STTService.isMuted`), and an end button (Escape).

`ChatView.voicePhase` derives the phase from `VoiceState`, `STTService.isHearingSpeech`, and `TTSService.isPlaying`: `loading`, `waiting`, `hearing`, `thinking` (responding, nothing played yet), and `speaking`. While muted, `listen()` reads the level as zero and feeds no audio, so no utterance starts and one in progress ends. Ending voice mode unmutes.

## Speech recognition

The streaming session is created with `language: nil` so Qwen3-ASR detects the language; the library default is English. Without a hint the model prefixes each decoded window with `language <Name><asr_text>`, which `STTService` removes from the transcript.

## Interruption

Capture and playback share one voice-processing engine so the system cancels the assistant's own voice from the microphone. When speech is detected during `responding`, `interruptVoiceResponse` stops playback and calls `ChatService.stopGenerating` in every phase of the response — compaction, prefill, thinking, tool calls, or streaming; the new utterance becomes the next turn, after the interrupted user message. The onset delay prevents short noises or residual echo from interrupting.

`stopVoiceMode`, and leaving the view, cancel the loop task, stop playback, and stop generation if a response was in progress. Cancelling the task ends any `listen()` in progress, which stops recording.

## Speech synthesis rules

- Sentences end at `。！？；!?;` or a newline. Incomplete text is held until it ends or the message completes. Until the response has queued any text, a clause of at least six characters ending at `，、：,:` is also spoken, so speech starts while the reply streams.
- Leading `<think>` reasoning is not spoken; speech starts after `</think>`.
- Text inside fenced code blocks is skipped, which also excludes [Generative UI](generative-ui.md) blocks.
- The first synthesized sentence is prepared once as reference conditioning and reused as an in-context voice prompt so later sentences keep the same voice without re-encoding it.
- Synthesis competes with the language model for the GPU and can fall behind real time. `TTSService` averages synthesis speed and seconds of speech per character over recent sentences; before a sentence starts playing, or resumes after its queue ran dry, it waits until the queued plus buffered audio covers the time needed to synthesize the rest of the sentence (at least 0.5 s, or 1 s while the speed is unknown), so pauses fall between sentences rather than every few words. A sentence that is already playing schedules each chunk as it is decoded.
- `finish()` waits until queued sentences have been synthesized and played; `stop()` discards them.

## Platform requirements

Voice mode needs microphone permission (`NSMicrophoneUsageDescription` and the audio-input entitlement). A recording failure or cancellation ends the current `listen()` call with `nil`, which ends the loop.
