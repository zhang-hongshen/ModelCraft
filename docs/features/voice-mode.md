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

`STTService` and `TTSService` are app-wide environment objects created in `ModelCraftApp`. Both models load lazily on the first voice session and download through the Hugging Face cache when absent.

## Loop

1. Load both models, then start listening.
2. `listen()` waits until the level stays above the speech threshold for 300 ms, keeps 0.5 s of pre-roll so the first syllable is transcribed, and ends the utterance after 1 s of silence.
3. A non-empty transcript is sent with `ChatService.sendMessage`, like typed input, to the open chat or a new one created by `ChatView.openChat`. The loop keeps that chat for later turns.
4. While the response streams, `ChatView` feeds the latest assistant content to `TTSService.feed`; complete sentences are queued for synthesis. After the turn completes, every assistant reply in it is fed once more with `isComplete: true` so trailing text is spoken.
5. The next `listen()` starts as an `async let` as soon as the response begins, so the user can speak at any time.

## Interruption

Capture and playback share one voice-processing engine so the system cancels the assistant's own voice from the microphone. When speech is detected during `responding`, `interruptVoiceResponse` stops playback and calls `ChatService.stopGenerating`; the new utterance becomes the next turn. The onset delay prevents short noises or residual echo from interrupting.

`stopVoiceMode`, and leaving the view, cancel the loop task, stop playback, and stop generation if a response was in progress. Cancelling the task ends any `listen()` in progress, which stops recording.

## Speech synthesis rules

- Sentences end at `。！？；!?;` or a newline. Incomplete text is held until it ends or the message completes.
- Text inside fenced code blocks is skipped, which also excludes [Generative UI](generative-ui.md) blocks.
- The first synthesized sentence is reused as an in-context voice reference so later sentences keep the same voice.
- `finish()` waits until queued sentences have been synthesized and played; `stop()` discards them.

## Platform requirements

Voice mode needs microphone permission (`NSMicrophoneUsageDescription` and the audio-input entitlement). A recording failure or cancellation ends the current `listen()` call with `nil`, which ends the loop.
