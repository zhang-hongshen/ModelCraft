# Chat

This document owns the conversation feature: sending and resending messages, the agent request lifecycle, cancellation, context compaction, titles, context-usage display, the composer, user-interaction prompts, and how persisted messages are projected into the conversation UI. Read it before changing `ChatService`, `AgentExecutor`'s message handling, `ChatView`, `ChatInputView`, `MessageView`, `Chat`, or `Message`.

Tool schemas and execution are owned by [Tools](tools.md); `ui` blocks in assistant content by [Generative UI](generative-ui.md); spoken conversations by [Voice mode](voice-mode.md); project context by [Projects](projects.md).

## Data model

| Type | Role |
| --- | --- |
| `Chat` | One conversation. Owns `messages` (cascade delete), optional `project`, `title`, `summary`, `lastSummaryIndex`, `tokenCount` from the latest generation, and `toolAuthorization`, the approvals the user chose to always allow (see [Tools](tools.md#execution-approval)). |
| `Message` | One protocol message: `role` (`user`, `assistant`, `system`, `tool`), `content`, attached `files`, `status`, and for tool messages a JSON-encoded `toolCall` and `toolCallResult`. |
| `MessageStatus` | `new` (assistant placeholder, waiting for the first token), `generating`, `generated`, `failed`. `Chat.isGenerating` reads the last message's status. |

Messages are ordered by `createdAt` through `Chat.sortedMessages`; never rely on the order of the `messages` relationship array. `Message.toolCallStatus` derives `running`, `completed`, or `failed` from whether `toolCallResult` exists and whether it is an error.

Attachments are copied into the app's Documents directory by `Message.addFiles` while the message is a draft; `ChatService.sendMessage` then moves them into the chat's folder with `Message.moveFiles(to:)`. `Message.files` stores the copies, not the user's originals. An existing file with the same name is replaced.

### Chat folder

Every chat owns `Chat.directory`, `Application Support/ModelCraft/Chats/<chat-id>/`. It holds the chat's attachments and generated media. Outside a project it is also the working directory for relative tool paths and `execute_command`. `AgentExecutor.run` creates it and binds it as `ProjectToolContext.chatDirectory` for every turn. Deleting a chat, or the project that owns it, removes the folder with `Chat.deleteDirectory()`.

## Request lifecycle

Each `ChatView` owns one `ChatService`, which owns one `AgentExecutor` and one `UserInteractionCoordinator`.

1. `ChatView.submitMessage` requires a selected model and no compaction in progress. Without a chat it creates one through `ChatService.createChat(project: globalStore.newChatProject)` and moves navigation to it.
2. `ChatService.sendMessage` cancels background metadata work and any running generation, persists the user message, then runs `compactContextIfNeeded` followed by `AgentExecutor.run` inside one generation task identified by a request ID.
3. `ChatService.buildPrompt` assembles protocol messages: one system message from `PromptBuilder.system(project:summary:)`, which joins the bundled system prompt (`Resources/Prompts/system.md`), the project context when the chat belongs to a project, and the compaction summary when present, followed by the messages from `lastSummaryIndex` onward. The request carries exactly one system message, first, because chat templates such as Qwen3.5's reject a system message in any other position. `LMService.protocolMessages` pairs each tool message with the assistant tool call that produced it.
4. `AgentExecutor.run` persists an assistant message in `new` status and streams from `LMService.generate`. Text chunks append to that message and move it to `generating`; generation info updates `Chat.tokenCount`.
5. On a tool call, an empty assistant placeholder is deleted, a tool message is persisted in `generating` status, and the call is executed (see [Tools](tools.md) for approval and dispatch). The result is written into the same tool message, which is then appended to the protocol history, and `AgentExecutor` recurses for the next model step.
6. After the turn completes, `ChatService` starts a background task that generates a title when `Chat.title` is `nil`.

A request that fails, for example because the chat template rejects the prompt or the model cannot load, settles its assistant message the way `stopGenerating` does, and `ChatView` shows the error in a "Request Failed" alert; cancellation is not reported. `/compact` failures use the same alert.

`AgentExecutor` blocks the third consecutive identical tool call (same name and arguments) with an error result instead of executing it, so a looping model receives feedback rather than repeating the side effect.

### Cancellation and resend

- `stopGenerating` cancels any pending approval or user-input prompt, cancels metadata and generation tasks, and settles the current generating assistant message as `generated`. Partial text stays visible; an assistant message still waiting for its first token is deleted.
- A newer `sendMessage` supersedes the previous request; request IDs prevent a cancelled request from clearing the newer request's task.
- `resendMessage` deletes every message after the chosen user message and sends it again. If the deleted range reaches into the summarized prefix, the summary is discarded.

## Context compaction

Compaction keeps long conversations inside the model's context window without deleting persisted messages.

- Before each request, `compactContextIfNeeded` counts tokens for the prompt and current tool schemas. At 75% of `LocalModel.contextWindow` or more, it compacts.
- `compactContext` summarizes messages from `lastSummaryIndex` up to, but not including, the latest user message, merging any previous summary. It refuses to summarize while a message in that range is still generating.
- The summary prompt is `PromptBuilder.summarize`; message serialization is `PromptBuilder.compressionText`, which omits binary data and keeps tool names, arguments, results, and statuses.
- The result is stored in `Chat.summary` and `Chat.lastSummaryIndex`. Later prompts send the summary as a section of the system message and only the messages after the index.
- Users can compact manually with the `/compact` composer command. `ChatService.isCompacting` disables sending while it runs.

## Titles and context usage

Titles are generated once, in the background after the first completed turn, with `PromptBuilder.generateTitle`. Titles and compaction summaries go through `LMService.generateAuxiliary`, which prefers Apple's on-device model when available; see [Language models](models.md#inference). A failure or cancellation is ignored; a later turn tries again while the title is still `nil`. Users can rename chats from the sidebar.

`ContextWindowUsageView` shows `Chat.tokenCount` against `LocalModel.contextWindow`. `tokenCount` is the prompt plus generated tokens reported by the latest generation; it is not recomputed independently.

## Composer

`ChatInputView` edits a draft `Message` that is never persisted until submission.

- Images and movies can be attached through the file importer or Photos picker; drag and drop accepts any file URL. Attachments are sent as images or videos to vision-capable models by `LMService.toMessage`, based on the file's UTType.
- Typing `/` opens the command palette. `/compact` compacts the current chat. Skill entries insert an inline `/<skill-name>` token; the skill catalog and activation contract belong to [Tools](tools.md#skill-discovery).
- The model picker selects `GlobalStore.selectedModel` from `LocalModelStore`; when nothing is selected, the first discovered model is chosen.
- The permission mode picker beside it sets the global tool permission mode (see [Tools](tools.md#permission-modes)).
- The project picker on a new chat sets `GlobalStore.newChatProject`.

## User interaction prompts

`UserInteractionCoordinator` suspends the agent loop on a checked continuation and exposes one `pendingInteraction` at a time:

- `.userInput` — presented by `UserInputRequestView` for `request_user_input`; field behavior is defined in [Tools](tools.md#user-input).
- `.approval` — presented by `ToolApprovalRequestView`; approval scope is defined in [Tools](tools.md#execution-approval).

Cancelling the task or calling `cancel()` resumes the continuation with `CancellationError`, so a stopped chat never leaves a prompt waiting.

## Conversation presentation

Presentation is a projection over `Chat.sortedMessages` and must not reorder or mutate messages.

- `ConversationContentBuilder` groups each run of assistant and tool messages after a user message into one `AssistantTurn`, which is what the user perceives as a single reply.
- Within a turn, `ChatContentBuilder` collapses adjacent tool messages into a `toolCallGroup`, summarized by `ToolCallGroupSummary` (files read or edited, commands run). `text_to_image` messages always stay standalone so their visual result occupies the conversation.
- `MessageView` renders assistant text as Markdown and `ui` blocks; tool messages render through `ToolCallView`, which selects a specialized renderer or `DefaultToolRenderer`.

## File preview

Links in assistant content that use the `modelcraft-file-preview` scheme (`FilePreviewLink`), `file` URLs, or relative paths open in the file inspector instead of an external application. The inspector is the window's trailing column, attached to the `NavigationSplitView` in `RegularContentView` like the leading sidebar; its header shows the containing folder in a native `NSPathControl` path bar whose folders open in Finder; its file and visibility live in `GlobalStore`, and `ChatView` sets them and clears them when the chat changes. PDFs use PDFKit and types the system knows use Quick Look; a type no app declares, such as `.ipynb`, is shown as plain text when it is UTF-8 text. `ChatView.resolvedPreviewURL` resolves relative paths against the project working directory, or the chat's folder outside a project. In a project chat only files inside the working directory, the chat's folder, or reference resources can be previewed; other paths are discarded. Web URLs use the system action.

## Persistence notes

`ModelContainer.shared` uses an in-memory store in `DEBUG` builds, so chats do not survive relaunching a debug build. Release builds use the default persistent store. Changes to `Chat` or `Message` stored properties must keep existing release stores readable.
