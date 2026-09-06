# ModelCraft

ModelCraft is a local-first SwiftUI personal AI assistant for macOS with multimodal chat, local inference, projects and retrieval, media generation, and agent tools.

## Standing orders

- Read this file before every task, then only the linked documents whose trigger matches the change.
- Inspect the relevant implementation first. Make the smallest complete change and preserve existing behavior, persisted data, public contracts, and supported macOS versions.
- Prefer direct code and existing ownership. Do not introduce speculative abstractions, extra indirection, fallback layers, or defensive handling for impossible states.
- Do not add a `Coordinator`, `Manager`, `Service`, protocol, wrapper, dependency-injection layer, or background task merely to move existing logic elsewhere. Add a new abstraction only when it owns a real boundary or is required by multiple concrete consumers.
- Keep simple state and behavior with the type that owns it. Avoid asynchronous work when the value is already available from the current request, stream result, model state, or call path.
- Preserve unrelated user changes. Never reset, overwrite, reformat, or clean files outside the requested scope.
- Do not write unit tests or build the project.
- Code and configuration are the source of truth. Documentation records durable current contracts, not task history or reasoning.

## Critical product rules

- **Tool discovery belongs to the tool schema.** Do not encode tool-specific routing in the system prompt. Read [Tools](docs/features/tools.md) before changing tools, schemas, execution, or overlapping agent prompts.
- **SwiftUI is the default UI technology.** Prefer native SwiftUI and keep AppKit bridges narrow. Read [Design](docs/design.md) before changing views or interaction.

## Documentation index

- [Coding](docs/coding.md): implementation style, ownership, abstraction threshold, dependency flow, concurrency, and refactoring rules. Read before writing or restructuring code.
- [Architecture](docs/architecture.md): repository ownership, application flow, persistence, inference, agent/tool boundaries, and cross-feature dependencies. Read before changes spanning modules or altering ownership/lifecycle.
- [Design](docs/design.md): SwiftUI, state/data flow, macOS interaction, appearance, localization, accessibility, and chat/tool presentation. Read before UI work.
- [Documentation guide](docs/documentation.md): where durable knowledge belongs and when to update/create docs. Read before documentation changes or durable contract changes.
- [Tools](docs/features/tools.md): model-visible tool discovery, schemas, execution, results, failures, and UI. Read before Tool changes.
