# Generative UI

This document owns the `ui` block contract: the model-visible format, how assistant content is split and rendered, and failure behavior. Read it before changing the `Rich UI` section of `Resources/Prompts/system.md`, `GenerativeUIParser.swift`, `GenerativeUIView.swift`, or assistant content rendering in `MessageView`.

## Contract

The assistant renders native UI by writing a fenced code block tagged `ui` in its reply. The block is ordinary message text: it is persisted in `Message.content`, returned to the model with the conversation history, copied with the message, and skipped by `TTSService` like any code block. No separate storage or tool call is involved.

The block contains a JSON array of components, decoded with `Codable` into `GenerativeUIComponent`. Each component has a `type`; its other fields are read only by that type. Containers nest components in `children`, so the model composes layouts as a tree. The format is JSON rather than Swift because SwiftUI cannot be compiled at run time, and a data format keeps the UI native without interpreting code. The format is taught in the system prompt because it is an output format rather than a tool; tool selection still belongs to tool schemas as described in [Tools](tools.md).

`type` names a SwiftUI view where one exists and is matched case-insensitively. `row`, `column`, `card`, `stat`, `callout`, `table`, and `chart` are ModelCraft components; `row` and `column` remain as aliases of `hstack` and `vstack`.

| `type` | Fields | SwiftUI |
| --- | --- | --- |
| `vstack`, `column` | `alignment` (`leading` default, `center`, `trailing`), `spacing`, `children` | `VStack` |
| `hstack`, `row` | `alignment` (`center` default for `hstack`, `top` for `row`), `spacing`, `children` | `HStack` |
| `zstack` | `alignment`, `children` | `ZStack` |
| `grid` | `spacing`, `children` of `gridRow` (other children span the grid) | `Grid`, `GridRow` |
| `lazyVGrid` | `minWidth` (adaptive column width), `spacing`, `children` | `LazyVGrid` |
| `scrollView` | `axis: "horizontal"` scrolls; otherwise lays out inline | `ScrollView` |
| `section` | `title`, `footer`, `children` | `Section` |
| `groupBox` | `title`, `children` | `GroupBox` |
| `card` | `title`, `icon`, `children` | — |
| `disclosureGroup` | `title`, `expanded`, `children` | `DisclosureGroup` |
| `tabView` | `children`, each a tab named by its `title` | segmented `Picker` |
| `list` | `items`, `style: "numbered"`, `children` | — |
| `text` | `text`, `style`: `title` \| `headline` \| `caption` \| `secondary` | `Text` |
| `label` | `title`, `icon` | `Label` |
| `image` | `icon` (SF Symbol), `label` for accessibility | `Image(systemName:)` |
| `labeledContent` | `label`, `value` | `LabeledContent` |
| `divider`, `spacer` | — | `Divider`, `Spacer` |
| `link` | `title`, `url` | `Link` |
| `progressView` | `label`, numeric `value`, `total`; indeterminate without `value` | `ProgressView` |
| `gauge` | `label`, numeric `value`, `minimum`, `maximum`, `detail` | `Gauge` |
| `stat` | `label`, `value`, `detail`, `trend`: `up` \| `down` \| `flat`, `icon` | — |
| `callout` | `kind`: `info` \| `success` \| `warning` \| `error`, `text`, `title` | — |
| `table` | `columns`, `rows` (arrays of strings); the first column is styled as the row label | `Grid` |
| `chart` | `kind`: `bar` \| `line` \| `area` \| `point` \| `pie`, `x` and `y` axis titles, `points` of `{label, value, series}` | Swift Charts |
| `map` | `places` of `{title, latitude, longitude}` | `Map` with `Marker`s |
| `button` | `title`, and `send` or `url` | `Button` |
| `form` | `title`, `submit`, `fields` of `{label, kind, value, on, options, minimum, maximum, step}` with `kind` `text` \| `toggle` \| `picker` \| `slider` \| `stepper` \| `date` | `Form` |

Every component also accepts modifiers named after SwiftUI's: `font` (text styles from `largeTitle` to `caption2`), `weight`, `color` and `background` (adaptive system colors and `primary` through `quinary`), `padding`, `cornerRadius` (shapes the background), `width`, `height`, and `fillWidth`. A modifier that is not set leaves inherited values unchanged, and sizes are clamped. Text in `text`, `callout`, `list`, `table`, and `labeledContent` supports inline Markdown.

Decoding is lenient so a small type mistake does not discard a block: numbers, Booleans, and strings convert into each other where a field needs it, and an element of `children`, `points`, `places`, `fields`, or the top-level array that cannot be decoded is dropped on its own. Dates in forms are exchanged as `yyyy-MM-dd`.

## Rendering

`MessageContentSegment.segments(of:isComplete:)` splits assistant content into leading reasoning (`<think>…</think>`), Markdown, and `ui` segments. A `ui` fence inside another fenced code block remains code. Segments are identified by their starting line so they keep identity while content streams.

A `ui` block renders while it streams. `MessageContentSegment.completingPartialJSON` keeps the longest prefix that ends after a complete value or inside a string value, then closes the open string, objects, and arrays, so a card appears with its title and its children appear one by one. Every field of `GenerativeUIComponent`, `GenerativeUIChartPoint`, and `GenerativeUIFormField` is optional for this reason: the newest object may not have its `type` yet. Components are identified by position, which stays stable as content is appended; a form keeps only the user's edits by field position, so fields can keep arriving. Until the opening `[` of the array arrives, a small progress indicator is shown.

## Actions

Actions are a closed set; a block cannot run code or call tools.

- A button's `send` text and a form submission create a user message in the same chat through `ChatService.sendMessage`. A form message has the form title, if any, followed by one `label: value` line per field, so the user bubble and the model input are the same text. A submitted form stays disabled.
- `form` is for adjusting an answer the assistant has already given. Information the assistant needs before it can answer is collected by the `request_user_input` tool, whose schema owns that choice.
- A button's `url` and links in text open only `http`, `https`, and `mailto` URLs.
- Buttons and forms are disabled while the containing message is still generating.

## Failure behavior

- A closed block that is not a valid JSON array of components is shown as a Markdown code block. An unclosed block in a completed message is shown the same way.
- An unknown or not-yet-streamed `type` renders nothing; missing fields render empty; chart points without a label or value and places without coordinates are skipped.
