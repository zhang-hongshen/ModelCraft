# Chat

This document owns conversations and local tasks: the Thread/Ticket/Assignment/Executor Session models, Input/Report records, memory boundaries and migration, sending and resending messages, the agent request lifecycle, cancellation, context compaction, titles, context-usage display, the composer, user-interaction prompts, and conversation projection. Read it before changing `ChatService`, `AgentExecutor`'s message handling, `TaskTool`, chat views, `Chat`, `Message`, or task persistence.

Tool schemas and execution are owned by [Tools](tools.md); `ui` blocks in assistant content by [Generative UI](generative-ui.md); dictation into the draft by [Voice input](voice-input.md); project context by [Projects](projects.md).

## Data model

| Type | Role |
| --- | --- |
| `Chat` | The Thread: owns the visible conversation, originating `tickets` (cascade delete), optional `activeTicket`, project, title, legacy thread summary/boundary, token usage and conversation approvals. |
| `Ticket` | A local user task: goal, structured status, task memory, one Executor Session and successive Assignments. Its originating Chat owns it. |
| `ExecutorSession` | Independent task history: input snapshots, references to persisted messages, durable `eventIDs` protocol order, and a checkpoint with the last covered event ID. It survives individual Assignments and can continue in another chat in the same project. |
| `Assignment` | One execution attempt with model ID, execution thread, start/end times and Reports. An ended turn does not imply a completed Ticket. |
| `TaskInput` / `TaskReport` | Persisted input snapshots with source message IDs, delivery/consumption metadata; structured execution progress, outcomes and blockers. |
| `Message` | One protocol message: `parentID`, `role` (`user`, `assistant`, `system`, `tool`), `content`, attached `files`, `status`, and for tool messages a JSON-encoded `toolCall` and `toolCallResult`. |
| `MessageStatus` | `new` (assistant placeholder, waiting for the first token), `generating`, `generated`, `failed`. `Chat.isGenerating` reads the leaf message's status. |

Messages form a chain, as in Claude Code transcripts: each message records the message it follows in `parentID`, and the first message has none. `Message.init` with a chat sets `parentID` to `Chat.leafMessage` before joining the chat, so every new message follows the current end of the conversation. `Chat.leafMessage` is the latest message nothing follows; `Chat.conversation` walks `parentID` up from it and returns the messages first to last. Read conversations through `Chat.conversation` and never rely on the order of the `messages` relationship array. Remove messages with `Chat.deleteMessages`, which drops them from the relationship immediately so the next message cannot link to a deleted one, and re-links any message that followed a deleted one to what the deleted one followed. `Message.toolCallStatus` derives `running`, `completed`, or `failed` from whether `toolCallResult` exists and whether it is an error.

`Message.addFiles` copies attachments into the message's chat folder, or into `Message.draftDirectory` (`Application Support/<bundle ID>/Drafts/`) while a new draft has no chat; `ChatService.sendMessage` then moves them into the chat's folder with `Message.moveFiles(to:)`. `Message.files` stores the copies, not the user's originals. An existing file with the same name is replaced. Drafts are not persisted, so the app removes the draft folder at launch.

### Chat folder

Every chat owns `Chat.directory`, `Application Support/<bundle ID>/Chats/<chat-id>/`. It holds the chat's attachments and generated media. Outside a project it is also the working directory for relative tool paths and `execute_command`. `AgentExecutor.run` creates it and binds it as `ProjectToolContext.chatDirectory` for every turn. Deleting a chat, or the project that owns it, removes the folder with `Chat.deleteDirectory()`.

## Request lifecycle

Each `ChatView` owns one `ChatService`, which owns one `AgentExecutor` and one `UserInteractionCoordinator`. These existing owners also run Tickets; there is no separate task scheduler or routing agent.

Ordinary follow-ups continue the active Ticket. A user-requested independent task starts a new Ticket through the `task` tool; explicit resume can select a Ticket from another chat in the same project. Task selection and pending input are saved before handoff. The next model step runs in the selected Session. Tasks outside projects stay within their originating chat. Selecting a task does not transfer or expand conversation approvals. The originating chat owns the Ticket even when another chat resumes it; deleting it deletes its Tickets, Sessions, Inputs, Assignments and Reports. Session-to-message references nullify rather than deleting conversation messages.

1. `ChatView.submitMessage` requires a selected model and no compaction in progress. Without a chat it creates one through `ChatService.createChat(project: globalStore.newChatProject)` and moves navigation to it.
2. `ChatService.sendMessage` cancels superseded work, persists the visible user message, creates an Assignment and snapshots its Input. A first execution adopts the retained conversation and any valid legacy summary checkpoint; later executions reuse the Session. A Ticket may have only one running Assignment.
3. Before **every model step**, `ChatService` assembles one system message with project context, Project Memory, the Ticket goal/status/memory/latest Report, and the Session checkpoint, followed by the Session's uncovered history. Inputs are represented as user messages without inserting duplicate chat messages. `LMService.protocolMessages` reconstructs assistant tool-call/result pairs. Inputs are marked consumed and saved before generation.
4. `AgentExecutor.run` persists an assistant placeholder and streams from `LMService.generate`. Assistant and tool messages join both the visible Chat and the executing Session; text chunks update the same visible reply and generation info updates token usage.
5. The model stream finishes before its calls execute, preserving completion info and every call in a multi-call batch. Before a tool's side effects, its intent is saved as a generating tool message. Its result is saved before the next model step. After a task handoff, remaining calls from that batch receive explicit not-executed results. The executor returns to `ChatService`, which ends the old Assignment and starts one for the selected Ticket. Otherwise the existing agent loop continues with the rebuilt Session context.
6. Normal turn completion ends the Assignment with a Report. Without a structured completion/blocker/failure report, the Ticket becomes `waiting`; a final assistant reply alone does not prove the task is complete. Title generation remains background metadata.

A request that fails, for example because the chat template rejects the prompt or the model cannot load, settles its assistant message the way `stopGenerating` does, and `ChatView` shows the error in a "Request Failed" alert; cancellation is not reported. `/compact` failures use the same alert.

`AgentExecutor` blocks the third consecutive identical tool call (same name and arguments) with an error result instead of executing it, so a looping model receives feedback rather than repeating the side effect.

### Cancellation, rewind and resend

- `stopGenerating` cancels pending user interaction, generation and metadata, settles unfinished tool calls with an interruption result, preserves partial assistant content, and records the Assignment as ended with a `paused` Ticket. An unfinished tool's result explicitly says the action may have taken effect and must be checked before repetition.
- A newer send supersedes the prior request; request IDs keep the old request from clearing the newer one.
- Rewind stops the current request, copies the selected user message’s text and attachments into an unpersisted composer draft, and deletes that message and the following conversation suffix immediately. It clears the active task and token usage; sending the draft starts from the retained conversation. Draft attachments are independent copies so removing one does not delete a retained message’s file.
- `resendMessage` removes the conversation suffix and starts a fresh task context from the retained thread, without the discarded task's memory. Removing a message covered by a Session checkpoint invalidates that checkpoint; removing a legacy summary boundary discards that summary.
- At launch, `Assignment.recoverInterrupted` ends persisted running Assignments as paused and settles their messages. Their Reports instruct the next execution to inspect actual tool/file state before repeating side effects. Pending input snapshots, task memory and checkpoints survive. Recovery waits for a user request; it does not replay external actions automatically.

## Context and memory boundaries

| Scope | Durable owner | Meaning |
| --- | --- | --- |
| Thread | `Chat.messages`, legacy `summary` / `summaryBoundaryID` | User-visible conversation and its historical compression boundary. |
| Task memory | `Ticket.memory` | Concise task facts, decisions, verified work and remaining steps, explicitly updated through structured Reports. |
| Execution context | `ExecutorSession.checkpoint` / `checkpointThroughID`, messages and Inputs | A compressed prefix plus original uncovered protocol events, reused across Assignments. |
| Project Memory | `Project.memory` | User-curated long-term project facts shared across conversations; see [Projects](projects.md). |

Checkpoint generation never overwrites task or project memory. Creating a separate task does not inherit another task's checkpoint. The `task` tool can page through the original Session transcript to recover detail omitted by summarization. Tool discovery comes from that Session's successful tool-search results, including after a resume in another chat.

## Context compaction

- Before each model step, tokenize the actual prompt and tools; at 75% of the selected model's context window, compact the Session.
- Prefer preserving the latest user message and its following work. If that entire turn is large, summarize its completed prefix while retaining its latest protocol event. `LMService.protocolMessages` keeps a retained tool result paired with its call.
- `PromptBuilder.summarize` and `compressionText` preserve task constraints, actions, results and unresolved work while omitting binary data. The prior checkpoint is merged with the newly covered prefix. An empty summary fails without advancing the boundary.
- Commit checkpoint text and the **last covered event ID** together. Original messages and Inputs remain stored; memory is not inferred from the checkpoint.
- `/compact` compacts the active Session. For a legacy chat with no active Ticket, it still updates the thread summary and its first-uncovered-message boundary. `isCompacting` disables sending during compaction.

## Titles and context usage

Titles are generated once, in the background after the first completed turn, with `PromptBuilder.generateTitle`. Titles and compaction summaries go through `LMService.generateAuxiliary`, which prefers Apple's on-device model when available; see [Language models](models.md#inference). A failure or cancellation is ignored; a later turn tries again while the title is still `nil`. Users can rename chats from the sidebar.

`ContextWindowUsageView` shows `Chat.tokenCount` against `LocalModel.contextWindow`. `tokenCount` is the prompt plus generated tokens reported by the latest generation; manual compaction replaces it with the rebuilt prompt's count. Hovering it shows the system prompt, tools, and messages, largest first. `ContextUsage.measure` tokenizes the same active Ticket/checkpoint/project-memory system prompt and tool schemas as execution with `LMService.tokenCounts` (the loaded model's tokenizer, or the tokenizer alone without loading weights); messages are the rest of `tokenCount`, including chat-template formatting and attached media.

## Task inspector

The chat toolbar's right-sidebar button toggles the trailing inspector owned by `ChatView`, preserving the selected tab when hiding or showing it. Its Tasks and Files tabs share visibility in `GlobalStore.isInspectorPresented`; tab selection is local to the chat view. Both tabs retain their view state while switching. Opening a file selects Files; changing chats clears the file and selects Tasks without closing an open inspector.

`TaskInspectorView` observes Tickets through `Ticket.fetch(chat:project:)`: all tasks originating in the selected project, or only the current chat outside projects. It is a read-only list grouped into In Progress and Completed, with empty groups omitted. Rows show the task title, status icon and a Current marker for the active task. The inspector has no detail pane, task actions or memory editor; task execution continues through chat and tools.

Ticket titles are stored separately from goals. Chat/tool-created tasks derive their initial title from the first line of the input, up to 60 characters. The inspector toggle is the rightmost action in the chat toolbar; the toolbar has no More menu or move/delete actions.

Project Memory is edited separately in the project editor; the task inspector never mixes it with task memory.

## Composer

`ChatInputView` edits a draft `Message` that is never persisted until submission.

The composer starts as one capsule row: Add Files on the leading arc, the editor in the middle, and a microphone for an empty draft or Send for text/attachments. It grows with its content up to six lines, then scrolls without visible scrollbars. Voice input replaces the editor with a waveform and blocks editing until its transcript is inserted; see [Voice input](voice-input.md).

- Return sends the draft (or runs the selected command while the palette is open); Command-Return inserts a new line. Return that confirms an input method's composition is consumed by the input method and does not send.
- Images and movies can be attached through the file importer or Photos picker; drag and drop accepts any file URL. Attachments are sent as images or videos to vision-capable models by `LMService.toMessage`, based on the file's UTType.
- Files can be dropped anywhere on the chat view, not only on the input. Files dropped on the sidebar's New Chat row or a project row, dropped on the Dock icon, or opened with ModelCraft from Finder start a new chat (in that project) with the files attached: the sender calls `GlobalStore.startNewChat(in:attaching:)`, and `ChatView` moves `GlobalStore.newChatFiles` into the draft. Dock and Finder files arrive through `onOpenURL` on the main window, which `handlesExternalEvents` reuses instead of opening another; Info.plist declares `public.item` as a document type with the `Alternate` rank, so ModelCraft never becomes a default opener.
- `GlobalStore.newChatPrompt` is a message for the new chat to send as soon as `ChatView` shows; [Quick Entry](quick-entry.md) uses it. Without a selected model it is left in the draft instead.
- Typing `/` opens the command palette. `/compact` compacts the current chat. Skill entries insert an inline `/<skill-name>` token; the skill catalog and activation contract belong to [Tools](tools.md#skill-discovery).
- The model picker below the capsule selects `GlobalStore.selectedModel` from `LocalModelStore`; when nothing is selected, the first discovered model is chosen.
- The permission mode picker at the leading edge of that same lower row sets the global tool permission mode (see [Tools](tools.md#permission-modes)).
- The project picker on a new chat sets `GlobalStore.newChatProject`.

## User interaction prompts

`UserInteractionCoordinator` suspends the agent loop on a checked continuation and exposes one `pendingInteraction` at a time:

- `.userInput` — presented by `UserInputRequestView` for `request_user_input`; field behavior is defined in [Tools](tools.md#user-input).
- `.approval` — presented by `ToolApprovalRequestView`; approval scope is defined in [Tools](tools.md#execution-approval).

Cancelling the task or calling `cancel()` resumes the continuation with `CancellationError`, so a stopped chat never leaves a prompt waiting.

## Conversation presentation

Presentation is a projection over `Chat.conversation` and must not reorder or mutate messages.

- `ConversationContentBuilder` groups each run of assistant and tool messages after a user message into one `AssistantTurn`, which is what the user perceives as a single reply.
- Within a turn, `ChatContentBuilder` collapses adjacent tool messages into a `toolCallGroup`, summarized by `ToolCallGroupSummary` (files read or edited, commands run). `text_to_image` messages always stay standalone so their visual result occupies the conversation.
- `MessageView` renders assistant text as Markdown and `ui` blocks; tool messages render through `ToolCallView`, which selects a specialized renderer or `DefaultToolRenderer`. Streaming Markdown uses the renderer’s existing text fade-in animation unless Reduce Motion is enabled; completed messages render without animation.

## Importing agent sessions

`SessionImportView` imports another agent app's sessions without a file picker: "Import from" picks a `SessionSource` (Claude Code, Codex, or WorkBuddy, each with its icon from `Assets.xcassets/Agents`), and Load runs `SessionSource.importSessions`. It sits in Settings > General. Each imported chat records its session ID in `importedSessionID`, and sessions already imported are skipped, as are transcripts with no conversation. A session joins the project for its working directory through `Project.forImportedSession`: the project whose working folder it is, or else a new project named after the folder, created once and reused by later sessions in that folder. Sessions run in the home folder, in an app's folder under `~/Library` (such as WorkBuddy's scratch workspaces), or in a folder that no longer exists stay outside projects.

### Claude Code

`Chat.importClaudeCodeSessions`, which imports every session transcript in `~/.claude/projects` (`Chat.claudeCodeSessionsDirectory`): the top-level `.jsonl` files of each working-directory folder (the file name is the session ID), leaving out subagent transcripts in subfolders. `Chat.importClaudeCodeSession` reads each one the way Claude Code does: from the latest non-sidechain message entry up through `parentUuid`, following `logicalParentUuid` across compaction boundaries, so entries such as attachments link the chain without becoming messages. It creates a new chat:

- User text becomes user messages; base64 images are written to the chat folder as attachments. Meta entries and compaction summaries are skipped.
- Assistant text becomes assistant messages, with the entries of one reply joined into one message; thinking is left out.
- Each `tool_use` becomes a tool message whose `toolCall` keeps Claude Code's tool name, arguments, and ID; the matching `tool_result` fills its result and status. A call without a result is recorded as failed.
- The latest `custom-title` becomes the title, and the latest entry's `cwd` picks the project.

### Codex

`Chat.importCodexSessions`, which imports the rollouts under `~/.codex/sessions` (`Chat.codexSessionsDirectory`, one folder per day); the session ID is the end of the `rollout-<time>-<ID>.jsonl` file name. Compressed `.jsonl.zst` rollouts and subagent sessions (a `session_meta` with `parent_thread_id`) are skipped. Each rollout line is read in order:

- `user_message` events become user messages, so the context Codex injects as user-role response items is left out; their data-URL images are written to the chat folder.
- Assistant `message` response items become assistant messages, with consecutive ones joined into one message; reasoning is left out.
- `function_call`, `custom_tool_call` (its `input` as the `input` argument), and `local_shell_call` (its `action` as arguments, named `shell`) become tool messages; the matching `*_output` item fills the result. A call without an output is recorded as failed.
- The title is the session's latest `thread_name` in `~/.codex/session_index.jsonl`, and `session_meta.cwd` picks the project.

### WorkBuddy

`Chat.importWorkBuddySessions` imports the top-level `.jsonl` transcripts in `~/.workbuddy/projects` (`Chat.workBuddySessionsDirectory`), one folder per working directory, with the file name as the session ID; saved tool results in subfolders are not sessions. Lines are read in the order written, and an entry ID seen before is skipped:

- A user `message` keeps only the last `<user_query>` in its text, leaving out the context WorkBuddy wraps around it; a user message without one (task notifications, summaries) is left out. Its `input_image` blocks are copied from WorkBuddy's blob store into the chat folder.
- Assistant `message` entries become assistant messages, with consecutive ones joined into one message; `reasoning` entries are left out.
- `function_call` becomes a tool message, and the `function_call_result` with the same `callId` fills its result. A call without a result is recorded as failed.
- The latest `ai-title` becomes the title, and the latest entry's `cwd` picks the project.

Imported messages get new IDs. Deleting an imported chat lets the next import bring it back.

## File preview

Links in assistant content that use the `modelcraft-file-preview` scheme (`FilePreviewLink`), `file` URLs, or relative paths open in the file inspector instead of an external application. The Files tab of the chat's trailing inspector shows previews; its header shows the containing folder in a native `NSPathControl` path bar whose folders open in Finder. The file URL and inspector visibility live in `GlobalStore`, while `ChatView` owns tab selection and clears the file when the chat changes. PDFs use PDFKit and types the system knows use Quick Look; a type no app declares, such as `.ipynb`, is shown as plain text when it is UTF-8 text. `ChatView.resolvedPreviewURL` resolves relative paths against the project working directory, or the chat's folder outside a project. In a project chat only files inside the working directory, the chat's folder, or reference resources can be previewed; other paths are discarded. Web URLs use the system action.

## Persistence notes

`ModelContainer.shared` uses an in-memory store in `DEBUG` builds, so chats do not survive relaunching a debug build. Release builds use the default persistent store. Changes to `Chat` or `Message` stored properties must keep existing release stores readable. Stores written before `parentID` existed are migrated at launch by `Chat.linkLegacyMessages`, which links each chat with more than one root message in `createdAt` order; a summary from such a chat is discarded because its old position-based boundary did not survive the migration.

### Task schema compatibility

The task schema adds new entities and optional/default-valued relationships and attributes to `Chat`, `Message` and `Project`; it retains the existing entity names, IDs, summary fields and message chain. `ModelContainer.shared` uses automatic lightweight migration, with no store reset or eager task classification. Existing and newly imported conversations become task-backed on their next send; a valid legacy summary becomes that first Session's checkpoint, never Ticket or Project Memory. New projects start with empty long-term memory.

The design adopts the separation of Ticket, Assignment, Input/Report and persistent Executor Session from [DSH's domain model](https://github.com/deepseek-ai/dsh-superagent-prototype/blob/main/docs/001-domain.md) and [execution contract](https://github.com/deepseek-ai/dsh-superagent-prototype/blob/main/docs/003-execution.md). ModelCraft uses its local conversation as Thread and input source, and its existing agent loop as Executor. It has no external Source, subscription fan-out, admission router, worktree lifecycle or effect-delivery service.
