# Language models

This document owns the chat language models: discovery in the Model Store, download and delete tasks, on-disk layout, local model discovery, context-window resolution, selection, and loading through `LMService`. Read it before changing `ModelService`, `ModelTask`, `LocalModelStore`, `LMService`, the Model Store or Downloaded Models views, or the model download location.

Image, video, and audio models are managed separately; see [Media generation](media-generation.md).

## Storage layout

All models download through `HubApi.default`, whose base directory is the `modelDownloadBaseDirectory` setting (default `~/Library/Application Support/huggingface`). Repositories live under `<base>/models/<author>/<name>`, the standard Hugging Face snapshot layout. `HubApi` also conforms to MLX's `Downloader`, so MLX loading writes to the same place.

Changing the location in Settings > Storage moves the existing `models` folder to the new base and reloads `LocalModelStore`. It is disabled while any model task is running and refuses a destination that already contains a `models` folder.

## Discovery and download

- `ModelStore` searches Hugging Face through `ModelService.searchModel`, restricted to the `mlx-community` author and `mlx` filter, sorted by downloads. Each result is then fetched individually to obtain its size.
- Downloading or deleting creates a persisted `ModelTask` (`download` or `delete`) whose ID is `<model-id>-<type>`, so one model has at most one task of each type.
- `ModelCraftApp` polls for `new` tasks every 5 seconds, marks them `running`, and stores the running `Task` in `GlobalStore.runningTasks` keyed by model ID so the UI can cancel it.
- Download progress is written into the task's unit counts and fraction. A completed task is deleted and `LocalModelStore` reloads. Cancellation sets `stopped`; other errors set `failed`. Resuming or retrying sets the task back to `new` so the poller picks it up; removing a task deletes it and cancels its running `Task`.
- Deleting a model removes its repository folder. If it was the selected model, `GlobalStore.selectedModel` is cleared.

## Local models

`LocalModel` is a plain value, not a SwiftData entity. `LocalModelStore.reload()` scans `<base>/models/*/*` and builds one `LocalModel` per repository folder with its size and creation date, newest first. It runs at launch, when the app becomes active, and after download, delete, or relocation, so models copied in by other tools appear without a separate registry.

Repositories listed in `ToolDefinition.modelIDs` (the media-generation models) are excluded so they are never offered as chat models.

`contextWindow` is resolved from the repository:

1. `config.json` `max_position_embeddings`, preferring a nested `text_config` or `language_config`. When RoPE scaling of a known scalable type has `factor > 1`, the window is `max(declared, original_max_position_embeddings × factor)`.
2. Otherwise `tokenizer_config.json` `model_max_length` when it is a plausible value.
3. Otherwise 32,768 tokens.

The resolved window drives compaction and the context-usage indicator described in [Chat](chat.md#context-compaction).

## Selection

`GlobalStore.selectedModel` is the model used for every request from the chat view, including titles and summaries. It is in-memory UI state: the first discovered model is selected automatically when none is selected, and the choice is not persisted across launches.

## Inference

`LMService.shared` is the single entry point for chat inference.

- `generate(model:messages:tools:maxTokens:)` returns an `AsyncThrowingStream<Generation>` of text chunks, tool calls, and completion info. A `String`-returning overload collects the stream and strips a leading `<think>…</think>` block; it is used for titles and summaries.
- `tokenCount(model:messages:tools:)` renders the same prompt with tools and counts tokens.
- Models load with `MLXLMCommon.loadModelContainer`, first from the local repository and, if that fails, by downloading. Tokenizers come from swift-transformers through `TransformersTokenizerLoader`. Loaded containers are cached in an `NSCache` with a count limit of 5.
- Generation uses temperature 0.7, and images are resized to fit 1024 × 1024 before processing.
- Persisted messages become protocol messages through `LMService.protocolMessages`, which pairs every tool result with its originating assistant tool call. Attached image and movie files are passed as vision inputs.

Inference requests are not serialized globally; see [Architecture](../architecture.md#inference-and-media-runtimes).

### Custom model families

A model that MLXLMCommon cannot run is implemented under `Core/Models/<Family>/` and routed by `LMService` before the generic path. `DeepSeekFlash` (`deepseek-ai/DeepSeek-V4-Flash-Vision-Exp`) is the current case: `LMService` sends it to `DeepSeekFlashEvaluator`, which renders its own chat template and translates the model's DSML tool-call markup into `Generation` tool calls. Its sequence length is capped at 65,536 tokens. Any new custom chat family must provide both `tokenCount` and `generate` with the same `Generation` stream contract, so `ChatService` and `AgentExecutor` stay unaware of the family.
