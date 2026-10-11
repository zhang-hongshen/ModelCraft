# ModelCraft architecture

Read this before changing agent execution, inference, persistence, project knowledge, app navigation, or dependencies across feature boundaries. It is an ordered map of the running application; source types remain authoritative for implementation details.

## Composition

`ModelCraftApp` owns application launch, shared environment, model-container access, and background model tasks. The Xcode application target supports macOS only and combines SwiftUI product code with focused AppKit services for accessibility, file previews, pasteboard access, and screen control.

`ContentView` presents `RegularContentView`, whose split-view layout routes through `AppNavigationView` and `AppNavigationTab`. A feature should not create a parallel application-navigation source of truth.

## Ownership map

| Area | Owner | Responsibility |
| --- | --- | --- |
| App lifecycle and navigation | `ModelCraftApp.swift`, root content and navigation views | Environment setup, window/scene entry, destination selection, model-task polling |
| Feature UI | `Features/` | SwiftUI presentation and user interaction grouped by Chat, Project, Model, and Settings |
| Persistent state | `Models/Persistence/`, `ModelContainer.shared` | Projects, chats, messages, and model download/delete tasks (SwiftData) |
| UI/application state | `Models/Plain/`, `GlobalStore`, `UserSettings`, `LocalModelStore` | Selection, navigation, settings, running tasks, and chat models discovered on disk |
| Chat orchestration | `ChatService` | Request ownership, cancellation, compaction, title/context metadata, and agent invocation. See [Chat](features/chat.md) |
| Agent loop | `Core/Agent/AgentExecutor.swift` | Model steps, tool-call limits, approval, tool execution, results, and continuation |
| Language models | `ModelService`, `LocalModelStore`, `LMService` | Hugging Face search and download, local discovery, context windows, and chat inference. See [Language models](features/models.md) |
| Media generation | Media tools, `Core/Models/` families | Image, video, and audio generation runtimes. See [Media generation](features/media-generation.md) |
| Tools | `Core/Agent/Tools/`, `ToolExecutor` | Model-visible schemas, typed execution, structured results, and platform actions. See [Tools](features/tools.md) and [Computer use](features/computer-use.md) |
| Project knowledge | `Project`, `ProjectSearchIndex`, `SearchTool` | Working folder, read-only references, and local retrieval for project chats. See [Projects](features/projects.md) |
| Voice mode | `ChatView`, `STTService`, `TTSService`, `VoiceAudioEngine` | Spoken input and output over the normal chat path. See [Voice mode](features/voice-mode.md) |
| Settings | `Features/Settings/`, `UserSettings` | Stored preferences and their consumers. See [Settings](features/settings.md) |

## Conversation flow

1. A chat view asks `ChatService` to send or resend a persisted user `Message`.
   Promoting the new-chat landing view to its newly persisted `Chat` preserves the same `ChatView` identity so its in-flight `ChatService` and user-interaction coordinator remain attached to the visible conversation.
2. `ChatService` cancels superseded generation and metadata work, compacts context when required, assembles protocol messages, and invokes `AgentExecutor` with the selected `LocalModel`.
3. `AgentExecutor` requests a stream from `LMService` using the current model-visible tool schemas. Text chunks update a generating assistant message; final generation information settles timing and context usage.
4. A model tool call is persisted as a tool message after the model stream completes. `ToolExecutor` or a special coordinator executes it and returns both a structured `CallToolResult` and a model-facing tool message.
5. The result is persisted before the next model step. The next request receives the prior assistant tool call and tool result in protocol order.
6. `ChatContentBuilder`, `MessageView`, and tool renderers project persisted messages into UI. Presentation grouping must preserve the underlying assistant and tool sequence.

Cancellation leaves partial assistant content visible and settles any in-progress tool message. Optional title and context-usage work must not delay a newer user request.

## Tool boundary

`ToolDefinition` assembles the schema list for a model request. It is the same on every request so the prompt prefix stays reusable; only project-document search depends on the chat having a project. Tools that cannot run, such as network tools while offline, report that in their result. Every tool is exposed directly; see [Tools](features/tools.md#fixed-tool-set-and-native-applications).

The model sees tool names, descriptions, parameter schemas, and prior tool results. It does not see Swift implementation details. Tool selection knowledge belongs in those schemas; the [Tools feature guide](features/tools.md) owns the complete rule.

Tool execution crosses model JSON, filesystem, process, network, media-runtime, or platform-accessibility boundaries. Decode and validate at those boundaries, return structured results, and keep stored messages and UI status consistent with the actual outcome.

## Persistence and projections

SwiftData entities are the durable source of truth; `DEBUG` builds use an in-memory store. Relationships among `Project`, `Chat`, and `Message` define conversation ownership; changes must preserve existing stores and relationship semantics unless an explicit migration is part of the task.

Conversation builders and tool-call summaries are projections for display. They may derive sections and adjacent visual groups but must not mutate or reorder persisted messages. A blank draft is not a completed conversation event, and an intermediate tool success is not final model-stream settlement.

## Inference and media runtimes

`LMService` is the shared language-model entry point; [Language models](features/models.md) owns its loading and routing. Inference requests are not globally serialized: each chat and media request enters its model runtime independently, while model-specific loading, caches, and memory profiles remain owned by that model's service or implementation. Resource exhaustion is reported as an inference failure rather than prevented by an application-wide lease.

Model-family implementations live under `Core/Models/`. Shared orchestration belongs in services; architecture, tensor rules, decoding, and runtime profiles that are specific to one model family stay in that model's directory. UI consumes service state and generated artifacts rather than importing model internals.

## Extension rules

- Add a screen inside its owning feature and route it through the existing navigation state.
- Add persistent behavior by extending the owning SwiftData model and its service path; do not make a view a second persistence layer.
- Add agent behavior through a clear prompt, skill, or tool boundary. A new tool follows the [Tools feature guide](features/tools.md); do not teach tool routing through the system prompt.
- Add shared behavior only after a real ownership boundary exists or two concrete consumers need the same contract; prefer extending the existing owner over introducing another coordinator/service layer.
- Keep request metadata and derived inference values on the path that already produces them; do not add background inference or coordination work to rediscover values already available from the active request.
- Add shared UI behavior only after two real consumers need the same contract, following [Design](design.md).
- Keep AppKit APIs inside focused adapters with small SwiftUI-facing boundaries.
- Update this document when ownership or the end-to-end flow changes; do not add local type inventories that will drift from source.
