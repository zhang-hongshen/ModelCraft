# ModelCraft

ModelCraft is a local-first SwiftUI personal AI assistant for macOS, iPhone, and iPad. It provides multimodal chat, local model inference, projects and document retrieval, media generation, and agent tools.

## Standing orders

- Read this file before every task, then read each linked document whose trigger matches the change.
- Inspect the relevant implementation before editing. Make the smallest coherent change and preserve existing behavior, persisted data, public contracts, and platform support.
- Preserve unrelated staged, unstaged, and untracked work. Never reset, overwrite, reformat, or clean files outside the requested scope.
- Prefer direct implementation over speculative abstractions, broad refactors, fallback layers, or defensive code for impossible states.
- Do not write unit tests or build the project.
- Code and configuration are the source of truth. Durable documentation describes current contracts and architecture, not task history or reasoning transcripts.
- Keep each fact in one authoritative document. Link to that document instead of duplicating its details.

## Critical product rules

- **Tool discovery belongs to the tool schema.** A tool's description and parameter descriptions must make its capability, selection conditions, constraints, effects, and result clear enough for a model to discover and use it without prior prompt knowledge. Never put tool-specific routing such as “when X happens, call tool Y” in a system prompt. Read the [Tools feature guide](docs/features/tools.md) before changing tools, tool schemas, tool execution, or agent prompts.
- **SwiftUI is the default UI technology.** Prefer native controls, layout, navigation, presentation, materials, and interaction. Use AppKit/UIKit only for a platform capability SwiftUI cannot provide, and keep the bridge narrow. Every UI change must work in Light and Dark appearances. Read [Design](docs/design.md) before changing views or user interaction.

## Task workflow

1. Check repository status and identify user-owned changes in the affected files.
2. Read the documentation routed below and inspect the actual call path, data model, and UI state involved.
3. State the behavior or contract that must remain true, then implement the narrowest complete change.
4. Update the owning document when architecture, tool contracts, UI conventions, or another durable rule changes.
5. Review the targeted diff and run static consistency checks only; do not run tests or builds.

## Project documentation

- [Architecture](docs/architecture.md) maps the repository, module ownership, application composition, conversation and tool lifecycle, persistence, inference, project knowledge, and extension boundaries. Read it before locating code across modules or changing any of those areas.
- [Design](docs/design.md) owns UI and interaction conventions: SwiftUI usage, platform adaptation, Light and Dark appearances, layout, state, localization, accessibility, and chat/tool presentation. Read it before changing views or user interaction.
- [Documentation guide](docs/documentation.md) defines where durable knowledge belongs and when to read, update, create, or skip documentation. Read it before changing documentation or when a code change alters a durable contract.
- For a local implementation detail that changes no durable contract, inspect the owning code; no new document is required.

## Feature documentation

- [Tools](docs/features/tools.md) defines the Tool feature's model-visible discovery, schemas, parameters, execution, results, failures, and UI presentation. Read it before changing the Tool feature or an agent prompt that may overlap with Tool-owned knowledge.
