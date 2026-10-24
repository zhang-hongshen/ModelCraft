# Language models

This document owns the chat language models: discovery in the Model Store, download and delete tasks, on-disk layout, local model discovery, context-window resolution, selection, and loading through `LMService`. Read it before changing `ModelService`, `ModelTask`, `LocalModelStore`, `LMService`, the Model Store or Downloaded Models views, or the model download location.

Image, video, and audio models are managed separately; see [Media generation](media-generation.md).

## Storage layout

All models download through `HubApi.default`, whose base directory is `~/Library/Application Support/ModelCraft`. Repositories live under `<base>/models/<author>/<name>`, the standard Hugging Face snapshot layout. `HubApi` also conforms to MLX's `Downloader`, so MLX loading writes to the same place.

System models (image, video, music, voice) use `HubApi.system`, whose base is `<base>/.system`, so they live under `<base>/.system/models/<author>/<name>`, apart from the chat models users download.

Changing the location in Settings > Storage moves the existing `models` and `.system` folders to the new base and reloads `LocalModelStore`. It is disabled while any model task is running and refuses a destination that already contains either folder.

## Discovery and download

- `ModelStore` searches Hugging Face through `ModelService.searchModel`, restricted to the `mlx-community` author and `mlx` filter, sorted by downloads, and to the `pipeline_tag` of the selected `ModelCategory` (Text `text-generation`, Vision `image-text-to-text`, Omni `any-to-any`). The API accepts one `pipeline_tag` per request and no exclusions, so categories are separate lists rather than a combined one. The search endpoint cannot return `usedStorage`, so each card fetches its size with `expand[]=usedStorage` when it appears; `ModelStore` keeps fetched sizes for its lifetime and a card scrolled away cancels its request. A card's icon is the avatar of `ModelStoreModel.organization`, resolved from a known family name prefix or else the `base_model` tag, falling back to the category symbol.
- Downloading or deleting creates a persisted `ModelTask` (`download` or `delete`) whose ID is `<model-id>-<type>`, so one model has at most one task of each type.
- `ModelCraftApp` polls for `new` tasks every 5 seconds, marks them `running`, and stores the running `Task` in `GlobalStore.runningTasks` keyed by model ID so the UI can cancel it.
- Download progress is written into the task's unit counts and fraction. A completed task is deleted and `LocalModelStore` reloads. Cancellation sets `stopped`; other errors set `failed`. Resuming or retrying sets the task back to `new` so the poller picks it up; removing a task deletes it and cancels its running `Task`.
- Deleting a model removes its repository folder. If it was the selected model, `GlobalStore.selectedModel` is cleared.

## Local models

`LocalModel` is a plain value, not a SwiftData entity. `LocalModelStore.reload()` scans `<base>/models/*/*` and builds one `LocalModel` per repository folder with its size and creation date, newest first. It runs at launch, when the app becomes active, and after download, delete, or relocation, so models copied in by other tools appear without a separate registry.

The app's own image, video, music, and voice models download through `HubApi.system` into `<base>/.system/models`, so the scan never sees them.

`contextWindow` is resolved from the repository:

1. `config.json` `max_position_embeddings`, preferring a nested `text_config` or `language_config`. When RoPE scaling of a known scalable type has `factor > 1`, the window is `max(declared, original_max_position_embeddings × factor)`.
2. Otherwise `tokenizer_config.json` `model_max_length` when it is a plausible value.
3. Otherwise 32,768 tokens.

The resolved window drives compaction and the context-usage indicator described in [Chat](chat.md#context-compaction).

## Selection

`GlobalStore.selectedModel` is the model used for every request from the chat view, including titles and summaries. It is in-memory UI state: the first discovered model is selected automatically when none is selected, and the choice is not persisted across launches.

## Inference

`LMService.shared` is the single entry point for chat inference.

- `generate(model:messages:tools:maxTokens:reusesPromptCache:)` returns an `AsyncThrowingStream<Generation>` of text chunks, tool calls, and completion info. A `String`-returning overload collects the stream and strips a leading `<think>…</think>` block; it never reuses the prompt cache, so titles and summaries do not evict the conversation's.
- `generateAuxiliary(model:messages:)` produces chat titles and compaction summaries. On macOS 26 or later, when `SystemLanguageModel.default.isAvailable` (Apple Intelligence supported and enabled), it uses Apple's on-device Foundation Models model with the system messages as instructions and the rest as the prompt. When the system model is unavailable or rejects the request (context size, language, guardrails), the selected model generates it through the `String` overload. Cancellation propagates instead of falling back. The app weak-links `FoundationModels` so it still launches on macOS 15.
- `tokenCount(model:messages:tools:)` renders the same prompt with tools and counts tokens.
- Models load with `MLXLMCommon.loadModelContainer`, first from the local repository and, if that fails, by downloading. Tokenizers come from swift-transformers through `TransformersTokenizerLoader`. Loaded containers are cached in an `NSCache` with a count limit of 5.
- Generation uses temperature 0.7, and images are resized to fit 1024 × 1024 before processing.
- Prompt cache: `LMService` keeps the KV cache of the last reusing request for one model, with that request's prompt tokens. The next reusing request for the same model trims it to the shared token prefix (always leaving at least one token to feed) and prefills only the rest; the previous reply is re-prefilled because the next prompt renders it from the persisted message. Only `LLMModel` text inputs without media or an explicit mask reuse it, and a cache that cannot be trimmed far enough is replaced. A running request takes the cache, so a concurrent one starts fresh. Completion info reports the full prompt token count.
- Persisted messages become protocol messages through `LMService.protocolMessages`, which pairs every tool result with its originating assistant tool call. Attached image and movie files are passed as vision inputs.

Inference requests are not serialized globally; see [Architecture](../architecture.md#inference-and-media-runtimes).

### Custom model families

A model that MLXLMCommon cannot run is implemented under `Core/Models/<Family>/` and routed by `LMService` before the generic path. `DeepSeekFlash` (`deepseek-ai/DeepSeek-V4-Flash-Vision-Exp`) is the current case: `LMService` sends it to `DeepSeekFlashEvaluator`, which renders its own chat template and translates the model's DSML tool-call markup into `Generation` tool calls. Its sequence length is capped at 65,536 tokens.

`DeepSeekFlash` runtime contracts:

- Weights: when the checkpoint fits in three quarters of physical memory, everything is resident and routed experts are stacked per projection at load, so a MoE step is three `gatherQuantizedMM` calls. Otherwise every non-expert tensor (attention, shared experts, gates, DSpark, vision, embeddings) is resident and routed experts are read from their block's shard on demand through `DeepSeekFlashExpertCache`, an LRU sized to the memory left after resident weights, a full-length attention cache, and a working set. Reads run on separate CPU streams so they overlap each other and GPU work; for short inputs the hash-routed layers' experts are prefetched at the start of the pass. Weights stay in their native MXFP4/FP8 formats.
- Attention memory: `DeepSeekFlashCache` owns the main and DSpark attention states, the committed tokens and images, and a snapshot taken at the end of each prompt. A forward pass stages new tokens and commits them per layer, or keeps them staged for verification until the caller commits the accepted prefix. Only the sliding-window ring and the compressor groups are committed or snapshotted; compressed rows written by rejected or discarded tokens are rewritten before any later token can see them.
- Prompt reuse: a request resumes from the live states when the new prompt extends all committed tokens, otherwise from the prompt-end snapshot when the new prompt shares it, otherwise it prefills from the first token. Images must already be committed at the same place with equal patches; a prompt with a new image prefills from the first token. Requests through the `String` overload use a temporary cache.
- Decoding: after each pass DSpark drafts a block from the target layers' hidden states; the leading drafts whose confidence is at least 0.5 are verified in one main pass, accepted by speculative sampling against greedy drafts (exact match at temperature 0), and only the accepted prefix plus one token is committed. Any new custom chat family must provide both `tokenCount` and `generate` with the same `Generation` stream contract, so `ChatService` and `AgentExecutor` stay unaware of the family.
