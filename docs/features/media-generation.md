# Media generation

This document owns local image, video, and audio generation: the generation tools, model selection and download in Settings, output files, progress, and the conventions shared by model-family implementations under `Core/Models/`. Read it before changing `ImageTool`, `VideoTool`, `AudioTool`, Settings > Models, a media model family, or a media tool renderer.

Tool schema rules belong to [Tools](tools.md); chat language models to [Language models](models.md).

## Capabilities

| Tool | Model family | Default model | Output |
| --- | --- | --- | --- |
| `text_to_image` | `StableDiffusion` | SDXL Turbo (`stabilityai/sdxl-turbo`) | PNG in the image output directory |
| `text_to_video` | `LTXVideo` or `MiniMaxH3` | LTX Video (`Lightricks/LTX-Video`); MiniMax H3 (`MiniMaxAI/MiniMax-H3`) is selectable | MP4 in the video output directory |
| `text_to_audio` | `MusicGen` | MusicGen Small (`facebook/musicgen-small` with EnCodec and T5) | WAV in the audio output directory |

Output directories default to Pictures, Movies, and Music and are changed in Settings > Storage. Files are named with a new UUID. A file written before a failure or cancellation is removed.

## Selection and availability

Settings > Models stores the selected image and video model IDs (`sdxl-turbo`, `minimax-h3`, `ltx-video`) in `UserSettings`. The tools read the same `UserDefaults` keys when their schemas are assembled:

- `text_to_image` is offered unless the image model ID is an empty string.
- `text_to_video` is offered unless the video model ID is empty. Its schema depends on the selection: LTX Video requires `ratio`, `resolution`, and a duration within LTX limits; H3 accepts only `prompt` and a 5–15 second duration at its fixed 768p canvas.
- `text_to_audio` is always offered.

Settings > Models downloads and deletes media models directly through each family's configuration, not through `ModelTask`. Deleting the selected model clears the image selection or falls back to another downloaded video model. A model that is selected but not downloaded is fetched on first use by its model factory.

Media repositories are listed in `ToolDefinition.modelIDs` so `LocalModelStore` does not offer them as chat models. Add every new media repository there.

## Execution and presentation

Generation runs inside the tool call, so the agent turn waits for the file. `ToolExecutor` stores a `resourceLink` to the file in the `CallToolResult`, which drives the UI. The persisted tool message `content` carries the output file URL and MIME type. `LMService.append` rebuilds the model-facing tool message from the persisted message and attaches image and video `resourceLink`s from the `CallToolResult` as message images and videos, so a vision model sees the generated media in the current turn and in later requests.

`ImageGenerationToolRenderer` and `VideoGenerationToolRenderer` show the result inline; image-generation messages stay standalone in the conversation (see [Chat](chat.md#conversation-presentation)). Audio results render through the default renderer's audio player.

Running progress is modeled by `StableDiffusionProgress` and `LTXVideoProgress`, which serialize to a `storedValue` string. `Message.imageGenerationProgress` and `videoGenerationProgress` decode that value from a running tool message's `content`. The tools report progress through the task-local handlers in `ToolExecutionProgressReporter`; `AgentExecutor` binds them around each tool call and writes each reported `storedValue` into the running tool message's `content` until the result replaces it.

## Model-family structure

Each family under `Core/Models/<Family>/` keeps its architecture, weights, and memory policy private and exposes one small entry point. The common roles are:

| Role | Responsibility |
| --- | --- |
| `<Family>Configuration` | Repository IDs, required files, presets, default parameters, and `download(progressHandler:)` through `HubApi.default`. |
| `<Family>Loader` / `IO` | Reading SafeTensors weights and decoding or writing media. |
| `<Family>ModelFactory` (actor) | Lazy download and load with an `idle` / `loading` / `loaded` state so concurrent callers share one load; releases weights on failure or eviction. |
| `<Family>Evaluator` | The public generation API used by the tool. |
| `<Family>RuntimeProfile` | Memory tier chosen from physical memory: quantization, tiling, step count, and whether a finished stage releases its weights before the next stage loads. |

Rules that apply across families:

- Keep tensor rules, decoding, and memory policy inside the family; tools pass plain parameters and receive an image, array, or file.
- Choose runtime behavior from a `RuntimeProfile`, not from scattered memory checks. The profile's doc comments are the authority for each tier.
- Check cancellation between expensive stages so stopping a chat stops generation promptly.
- Generation is not serialized across families or chats. Each family's factory owns its residency; running two large families at once can exhaust memory and surfaces as a tool error.

### Family notes

- **StableDiffusion**: `StableDiffusionEvaluator.shared` keeps the model loaded between calls. The profile selects quantization, step count, and stage release by memory tier.
- **LTXVideo**: the evaluator is a static instance on `VideoTool`, so the model stays loaded between calls; any generation error cleans up the factory so the next call reloads.
- **MiniMaxH3**: about 144 GB of weights across four components, so stages always release their weights and the Omni Transformer streams one SafeTensors shard at a time. `H3Evaluator` selects the FL2VA checkpoint, or Ref2VA when ordered references are supplied. A cached `H3Base` must not run two renders at once.
- **MusicGen**: the evaluator is a static instance on `AudioTool`, so the model stays loaded between calls. Below 8 GiB of memory limit the factory does not keep the model and loads components lazily.
