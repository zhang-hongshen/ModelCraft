# Language models

This document owns the chat language models: discovery in the Model Store, download and delete tasks, on-disk layout, local model discovery, context-window resolution, selection, and loading through `LMService`. Read it before changing `ModelService`, `ModelTask`, `LocalModelStore`, `LMService`, the Model Store or Downloaded Models views, or the model download location.

Image, video, and audio models are managed separately; see [Media generation](media-generation.md).

## Storage layout

All new chat, image, video, music, and voice downloads use `HubClient(cache: HubCache.default)` and return the cache snapshot directly. There is no per-app output copy and no separate `.system` cache. `HubCache` also implements MLX's `Downloader` through the app's extension in `Extensions/HubCache+.swift`.

The cache root follows swift-huggingface's location rules: `HF_HUB_CACHE`, then `$HF_HOME/hub`, then `~/.cache/huggingface/hub` for the current non-sandboxed macOS app. Repositories use `models--<author>--<name>/`, containing `blobs/` (file contents), `refs/` (branch-to-commit references), and `snapshots/<commit>/` (file links). Loaders read the resolved snapshot, never the blobs directory.

Model discovery, loading, downloading, and deletion use only the shared cache. ModelCraft does not scan, reuse, migrate, or remove the former private `models` or `.system/models` directories. Manual migration must produce the standard Hub cache structure, including repository refs and versioned snapshots; copying an author/model folder directly into the cache root does not make it discoverable.

Settings > Storage manages skill directories; it does not relocate the shared model cache. Cache environment overrides apply to the running App's environment, which may differ from a terminal shell.

## Package dependencies

The resolved `mlx-swift-lm` 3.32.3 package depends on `mlx-swift` and `swift-syntax`; it accepts host-provided downloading and tokenization. ModelCraft directly links `HuggingFace` from `swift-huggingface` for its shared cache/client, and `Tokenizers` plus `Hub` from `swift-transformers` for tokenization and `Hub.Config`. The `HubApi` downloader is not used. `mlx-audio-swift` 0.1.5 also depends transitively on both Hugging Face packages. Removing the direct package declarations would hide actual App dependencies, rather than remove these libraries from the graph.

## Discovery and download

- `ModelStore` searches Hugging Face through `ModelService.searchModel`, restricted to the `mlx-community` author and `mlx` filter, sorted by downloads, and to the `pipeline_tag` of the selected `ModelCategory` (Text `text-generation`, Vision `image-text-to-text`, Omni `any-to-any`). The API accepts one `pipeline_tag` per request and no exclusions, so categories are separate lists rather than a combined one. Search requests include `config=true`; only models whose `config.model_type` is registered in the linked `LLMTypeRegistry` or `VLMTypeRegistry` appear. Missing or unregistered types are excluded, including standalone MTP drafters. Pagination uses the unfiltered Hub page size and skips fully unsupported pages so filtering does not hide later supported results. Architecture registration establishes loader support, not a guarantee that every checkpoint has valid weights or a compatible chat template. The search endpoint cannot return `usedStorage`, so each card fetches its size with `expand[]=usedStorage` when it appears; `ModelStore` keeps fetched sizes for its lifetime and a card scrolled away cancels its request. A card's icon is the avatar of `ModelStoreModel.organization`, resolved from a known family name prefix or else the `base_model` tag, falling back to the category symbol.
- Downloading or deleting creates a persisted `ModelTask` (`download` or `delete`) whose ID is `<model-id>-<type>`, so one model has at most one task of each type.
- `ModelCraftApp` polls for `new` tasks every 5 seconds, marks them `running`, and stores the running `Task` in `GlobalStore.runningTasks` keyed by model ID so the UI can cancel it.
- Download progress is written into the task's unit counts and fraction. A completed task is deleted and `LocalModelStore` reloads. Cancellation sets `stopped`; other errors set `failed`. Resuming or retrying sets the task back to `new` so the poller picks it up; removing a task deletes it and cancels its running `Task`.
- Deleting a model explicitly removes its shared cache repository (all cached revisions). Confirmation identifies the cross-app consequence. If it was the selected model, `GlobalStore.selectedModel` is cleared. Other apps may need to download it again; models are never automatically evicted by ModelCraft.

## Local models

`LocalModel` is a plain value, not a SwiftData entity. `LocalModelStore.reload()` asynchronously scans only the shared cache's resolved `main` snapshots, producing one entry per model ID. It requires a registered LLM/VLM architecture (or the custom DeepSeekFlash model), excludes known media repositories, and checks for SafeTensors weights and every indexed shard. Speech and other unsupported models in the shared cache do not enter the chat picker. Sizes follow snapshot symlinks to their actual files instead of counting link lengths or every historical revision.

Reload runs at launch, when the app becomes active, and after download or delete. A later reload supersedes an older suspended reload so it cannot restore a stale list. Supported models downloaded by another App into the same cache appear on the next reload.

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
