# ModelCraft architecture

Read this before changing agent execution, inference, persistence, project knowledge, app navigation, or dependencies across feature boundaries. It is an ordered map of the running application; source types remain authoritative for implementation details.

## Composition

`ModelCraftApp` owns application launch, shared environment, model-container access, and background model tasks. The Xcode application target shares SwiftUI product code across macOS, iPhone, and iPad while platform-conditional services provide capabilities such as macOS accessibility and screen control.

`ContentView` selects the compact or regular application shell. `RegularContentView` uses a split-view layout; `CompactContentView` uses stack navigation. Both route through `AppNavigationView` and `AppNavigationTab`, so a feature should not create a parallel application-navigation source of truth.

## Ownership map

| Area | Owner | Responsibility |
| --- | --- | --- |
| App lifecycle and navigation | `ModelCraftApp.swift`, root content and navigation views | Environment setup, window/scene entry, destination selection |
| Feature UI | `Features/` | SwiftUI presentation and user interaction grouped by Chat, Project, Model, and Settings |
| Persistent state | `Models/Persistence/`, `ModelContainer.shared` | Projects, chats, messages, local models, and background model tasks |
| UI/application state | `Models/Plain/`, `GlobalStore`, feature services | Non-persistent selection, settings, and observable state |
| Chat orchestration | `ChatService` | Request ownership, cancellation, compaction, title/context metadata, and agent invocation |
| Agent loop | `Core/Agent/AgentExecutor.swift` | Model steps, tool-call limits, tool execution, results, and continuation |
| Model inference | `LMService`, `InferenceRuntimeCoordinator`, `Core/Models/` | Prompt execution, runtime leases, cache coordination, and model-family implementations |
| Tools | `Core/Agent/Tools/`, `ToolExecutor` | Model-visible schemas, typed execution, structured results, and platform actions |
| Project knowledge | `Project`, `KnowledgeIndexer`, `SearchTool` | Project-owned documents, indexing, and retrieval available to project chats |

## Conversation flow

1. A chat view asks `ChatService` to send or resend a persisted user `Message`.
2. `ChatService` cancels superseded generation and metadata work, compacts context when required, assembles protocol messages, and invokes `AgentExecutor` with the selected `LocalModel`.
3. `AgentExecutor` requests a stream from `LMService` using the current model-visible tool schemas. Text chunks update a generating assistant message; final generation information settles timing and context usage.
4. A model tool call is persisted as a tool message only after the model stream releases its inference lease. `ToolExecutor` or a special coordinator executes it and returns both a structured `CallToolResult` and a model-facing tool message.
5. The result is persisted before the next model step. The next request receives the prior assistant tool call and tool result in protocol order.
6. `ChatContentBuilder`, `MessageView`, and tool renderers project persisted messages into UI. Presentation grouping must preserve the underlying assistant and tool sequence.

Cancellation leaves partial assistant content visible and settles any in-progress tool message. Optional title and context-usage work must not sit ahead of a newer user request in the shared inference queue.

## Tool boundary

`ToolDefinition` assembles the schema list for a model request. Some capabilities are conditional: network tools require connectivity, and project-document search requires a project context. The schema list is therefore request context, not a static promise that every tool always exists.

The model sees tool names, descriptions, parameter schemas, and prior tool results. It does not see Swift implementation details. Tool selection knowledge belongs in those schemas; the [Tools feature guide](features/tools.md) owns the complete rule.

Tool execution crosses model JSON, filesystem, process, network, media-runtime, or platform-accessibility boundaries. Decode and validate at those boundaries, return structured results, and keep stored messages and UI status consistent with the actual outcome.

## Persistence and projections

SwiftData entities are the durable source of truth. Relationships among `Project`, `Chat`, and `Message` define conversation ownership; changes must preserve existing stores and relationship semantics unless an explicit migration is part of the task.

Conversation builders and tool-call summaries are projections for display. They may derive sections and adjacent visual groups but must not mutate or reorder persisted messages. A blank draft is not a completed conversation event, and an intermediate tool success is not final model-stream settlement.

## Inference and media runtimes

`LMService` is the shared language-model entry point. `InferenceRuntimeCoordinator` serializes or coordinates memory-intensive local workloads; callers must acquire and release work through the established service path rather than loading a competing runtime directly.

Model-family implementations live under `Core/Models/`. Shared orchestration belongs in services; architecture, tensor rules, decoding, and runtime profiles that are specific to one model family stay in that model's directory. UI consumes service state and generated artifacts rather than importing model internals.

## Extension rules

- Add a screen inside its owning feature and route it through the existing navigation state.
- Add persistent behavior by extending the owning SwiftData model and its service path; do not make a view a second persistence layer.
- Add agent behavior through a clear prompt, skill, or tool boundary. A new tool follows the [Tools feature guide](features/tools.md); do not teach tool routing through the system prompt.
- Add shared UI behavior only after two real consumers need the same contract, following [Design](design.md).
- Keep platform-specific APIs behind conditional, focused adapters so shared SwiftUI and non-supporting destinations remain valid.
- Update this document when ownership or the end-to-end flow changes; do not add local type inventories that will drift from source.
