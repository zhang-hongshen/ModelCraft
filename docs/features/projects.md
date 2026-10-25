# Projects

This document owns projects: the working folder and reference files, how project context reaches the model and tools, and the local project search index behind `search_project`. Read it before changing `Project`, project views, `PromptBuilder.system(project:summary:)`, `ProjectToolContext`, `ProjectSearchIndex`, `ProjectSearchReranker`, or `CodeStructureParser`.

## Model

`Project` is a SwiftData entity with a `title`, optional `workingDirectory`, `resources` (reference files or folders), and `chats` (cascade delete). URLs are stored standardized. A chat belongs to at most one project through `Chat.project`; recent chats are those with no project.

| Location | Meaning |
| --- | --- |
| Working directory | The project root. It is the default directory for relative tool paths and command execution, and the only place file writes may land. |
| Resources | Additional read-only context. A resource may be a file or a folder; folders are searched recursively. |

The project views set the working directory from a folder import or a dropped folder; dropped or imported files become resources. The app is not sandboxed, so URLs are stored directly rather than as security-scoped bookmarks.

## Context delivered to the model

For a project chat, `PromptBuilder.system(project:summary:)` appends a project context section to the system message. It lists the project name, root, and reference file paths, and states that the root is the default working directory and references are read-only. File contents are not inlined; the model reads or searches them through tools.

`AgentExecutor.run` binds the task-local `ProjectToolContext.workingDirectory` and `ProjectToolContext.readOnlyFiles` for the whole agent turn. File and command tools read these values:

- Relative paths resolve against the working directory, or the chat's folder (`Chat.directory`) outside a project.
- With a working directory, `apply_patch` rejects paths outside it. Without one, it rejects edits to reference files.
- `execute_command` runs in the working directory, or the chat's folder outside a project, and rejects a non-read-only command that names a reference file path.
- The working directory and the chat's folder are the initial file scopes for approval, so edits inside them do not ask again (see [Tools](tools.md#execution-approval)).

`search_project` is added to the tool schemas only for project chats, in both `ChatService.availableTools` and `AgentExecutor`. Its schema is the model-facing contract.

## Search index

`Project.search` opens a `ProjectSearchIndex` backed by SQLite FTS5 at `Documents/<project-id>.fts5`. `ProjectModelActor` performs the lookup off the main actor for the tool.

### Synchronization

Indexing is lazy: every search first collects the current files and synchronizes the index, so there is no background indexer and no file watching.

- Files come from the working directory (`workspace` source) and resources (`reference` source). Ignored directories include `.git`, `.build`, `DerivedData`, `node_modules`, `Pods`, and other build output; hidden directories are skipped except `.github` and `.vscode`. Symbolic links are not followed.
- Each file is classified as `code`, `document`, `structured_data`, or `transcript` by extension. Text files over 5 MiB are skipped. Audio transcripts are produced only for reference files.
- A file is reindexed when its `size:modification-date` fingerprint changes and removed when it disappears.
- `schemaVersion` is stored in `PRAGMA user_version`. Changing the schema requires bumping it; a mismatch drops all tables and rebuilds the index on the next search.

### What is indexed

| Kind | Content | Extra structure |
| --- | --- | --- |
| Code | 80-line chunks with 10-line overlap | Symbols and caller-callee edges from `CodeStructureParser` (SwiftSyntax for Swift, Tree-sitter for other supported languages) |
| Structured data | 80-line chunks | Keys inserted as symbols |
| Document | Paragraph-aware chunks; PDF via PDFKit, rich text and Office formats via `NSAttributedString` | `NLEmbedding` sentence embeddings |
| Transcript | Audio transcribed with Qwen3-ASR (`URL.readContent`), chunked like documents | Sentence embeddings |

### Query and ranking

1. `ProjectSearchPurpose.automatic` resolves to `edit`, `locate`, or `understand` from keywords in the query (English and Chinese).
2. Candidates come from path matches, symbol matches, call-graph neighbors, and FTS chunk matches; `understand` and `automatic` also add semantic matches with cosine similarity of at least 0.42.
3. `ProjectSearchReranker` merges candidates for the same path and location, combines their reasons and scores, and reranks with lexical and embedding signals weighted by purpose.

Results carry absolute paths, a location, line ranges where available, a snippet, and the match reason, so the model can `read_file` the exact region before editing.

## Lifecycle

- Adding resources ignores duplicates. Removing a resource also removes its rows from the index.
- Deleting a project deletes its index files (`.fts5`, `-shm`, `-wal`) and then the entity, which cascades to its chats and messages. If the current chat belonged to the project, navigation returns to a new chat.
- Moving a chat between projects or to Recents only changes `Chat.project`; the next request uses the new project context.
