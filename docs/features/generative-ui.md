# Generative UI

This document owns the `ui` block contract: the model-visible format, the SwiftUI interpreter that runs it, how assistant content is split and rendered, and failure behavior. Read it before changing the `Rich UI` section of `Resources/Prompts/system.md`, `GenerativeUIParser.swift`, `GenerativeUIInterpreter.swift`, `GenerativeUIView.swift`, or assistant content rendering in `MessageView`.

## Contract

The assistant renders native UI by writing SwiftUI code in a fenced code block tagged `ui`. The block is ordinary message text: it is persisted in `Message.content`, returned to the model with the conversation history, copied with the message, and skipped by `TTSService` like any code block. No separate storage or tool call is involved. The format is taught in the system prompt because it is an output format rather than a tool; tool selection still belongs to tool schemas as described in [Tools](tools.md).

SwiftUI cannot be compiled at run time, so the app interprets a subset of Swift instead of compiling it. Code is parsed with `SwiftParser` and run by `UIInterpreter`; it can only do what the interpreter implements, so a block cannot reach files, the network, other processes, or app state, and an error in it cannot crash the app. A block is either top-level views or a `struct ContentView: View`; without `ContentView`, the first view type declared is the root.

### Language

- Declarations: structs (classes behave as structs), enums with raw values, `CaseIterable`, and computed properties, extensions, methods, top-level functions, and top-level constants. Records get a memberwise initializer; custom initializers, protocols, generics, and `async` code are not supported.
- View types: stored properties with `@State` (also accepted: `@StateObject`, `@ObservedObject`, `@Bindable`) keep per-instance state; `@Binding` properties take a `$` binding; other properties are set by the memberwise initializer. Properties, methods, and functions returning a `View` are view builders.
- Statements: `let`, `var`, assignment and compound assignment, `if` and `if let`, `guard`, `switch` with value, range, and binding patterns, `for`-`in` with `where`, `while`, `repeat`, `break`, `continue`, `return`, and `if`/`switch` expressions.
- Expressions: literals with string interpolation (including `specifier:`), arrays, dictionaries, tuples, closures with named or `$0` parameters, operators with standard precedence, optional chaining, `??`, key paths, and `$` bindings to state, `@Binding` properties, their fields, and array elements.
- Built-ins: the common `String`, `Array`, `Dictionary`, number, `Bool`, and `Date` methods; `min`, `max`, `abs`, rounding and math functions; `String(format:)`; `Int`/`Double`/`String` conversions; `UUID()`, `Date()`, `Int.random(in:)`, `stride`, `zip`; `withAnimation`; and `send(_:)`.
- A run is limited to 200,000 evaluation steps so an endless loop fails instead of hanging.

### Views

`UIInterpreter.makeView` builds the supported SwiftUI views, and `applyModifier` the supported modifiers; the system prompt lists both. A modifier the interpreter does not know is ignored so styling never fails a block, while an unknown view or function is an error. Views the chat cannot host are adapted: a vertical `ScrollView`, `Form`, and `List` lay out in place because the chat already scrolls, and `Image` supports only SF Symbols. `Chart` content is collected as mark records and drawn by `UIChart`; `Map` content as `Marker` records drawn by `UIMap`. `Stat`, `Card`, and `Callout` are ModelCraft views for key figures, titled groups, and tinted notes.

Values are `UIValue`s. Views, colors, fonts, and shape styles are values too, so helpers can return them; built-in value types such as shapes, chart marks, grid items, and coordinates are records named after their SwiftUI type. An implicit member such as `.blue` or `.title.bold()` stays a member until its use converts it in `UIStyles`.

## Rendering

`MessageContentSegment.segments(of:isComplete:)` splits assistant content into leading reasoning (`<think>…</think>`), Markdown, and `ui` segments. A `ui` fence inside another fenced code block remains code. Segments are identified by their starting line so they keep identity while content streams.

A `ui` block is not run while it streams; a small progress indicator stands in until its closing fence arrives or the message completes. `GenerativeUIView` then parses the block into a `GenerativeUIProgram` and shows the root `InterpretedView`.

Each `InterpretedView` is one instance of a view type. Its `@State` values live in a `UIStateStore` held in SwiftUI `@State`, so they keep SwiftUI's identity rules: they survive re-renders and are reset when the view's position or `ForEach` id changes. The store is `@Observable`, so changing state re-runs only the bodies that read it. `ForEach` identifies elements by the `id:` key path, an `id` property, or the element itself; those ids also tag `Picker` options.

## Actions

- Buttons, gestures, `onAppear`, `onChange`, and timers run their closures with the variables they captured, against the same state store. A timer from `Timer.publish(every:…)` passed to `onReceive` runs as a view task.
- `send(_:)` creates a user message in the same chat through `ChatService.sendMessage`. It fails while the containing message is still generating.
- Links open only `http`, `https`, and `mailto` URLs.
- Information the assistant needs before it can answer is collected by the `request_user_input` tool, whose schema owns that choice.

## Failure behavior

- A block that does not parse, or whose body throws, shows `GenerativeUIErrorView` with the message and line, in place of the view that failed; sibling views keep rendering. Its "Ask to Fix" button sends the error as a user message so the model can rewrite the block.
- An error thrown by an action is shown under the block until an action succeeds.
- An unclosed block in a completed message is run as it is.
