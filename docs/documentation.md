# Documentation guide

This document defines how agents maintain ModelCraft's engineering documentation. Read it before changing documentation or when a code change may alter durable project knowledge.

## Purpose

Documentation is a navigation and contract layer over the codebase. It should prevent repeated discovery and preserve facts that future contributors need to make correct changes. Code and configuration remain the source of truth for implementation details.

Each fact has one authoritative home. Other documents link to that home instead of copying its content. `AGENTS.md` is the entry point: it keeps only standing orders, critical project rules, and a short index explaining what each document owns and when to read it.

## Read documentation when

- `AGENTS.md` routes the affected area to a project or feature document;
- the change crosses modules, changes ownership, or touches a documented lifecycle;
- the change affects a public, persisted, model-visible, user-visible, or platform contract;
- an unfamiliar subsystem has a feature guide that can prevent rediscovery or incompatible patterns.

Read only the owning documents needed for the task. Follow their links when the next layer is necessary; do not load the entire documentation tree by default.

## Update documentation when

Update the owning document in the same change when implementation alters any documented:

- responsibility, dependency direction, lifecycle, data flow, or extension point;
- persistence, compatibility, failure, cancellation, security, or platform behavior;
- model-visible Tool schema or feature-wide implementation contract;
- shared UI, interaction, appearance, localization, or accessibility convention;
- command, configuration, supported environment, or operational procedure.

Update current statements directly. Do not append a task diary, commit history, migration narration, or explanation of how the agent reached the answer.

## Create a document when

Create one focused document only when the knowledge is durable and at least one of these is true:

- a feature spans enough files or layers that contributors repeatedly need an ordered map;
- a subtle contract is easy to violate by editing only one implementation surface;
- multiple future changes need the same rules, lifecycle, or extension procedure;
- a consequential architectural decision needs a stable current-state description.

Put project-wide structure and cross-feature flows in `architecture.md`. Put shared UI rules in `design.md`. Put feature-specific contracts under `docs/features/<feature>.md`. Add every new durable document to the appropriate index section in `AGENTS.md` with both its contents and reading trigger.

Do not create a document for a local implementation detail, a one-off fix, temporary investigation, speculative future feature, or content already owned elsewhere. Do not use the product `README.md` files as engineering-agent indexes.

## Writing rules

- Describe the current system in direct, concrete language.
- State responsibilities, inputs, outputs, invariants, failure behavior, and extension points; do not restate line-by-line implementation.
- Keep lower-level detail in its owning feature document and link to it from higher levels.
- Use repository-relative Markdown links and verify every target exists.
- Prefer exact type, service, file, setting, and event names over vague architectural terms.
- Remove or rewrite stale statements when their subject changes; documentation is not an archive.
- Keep examples only when they clarify a contract that prose cannot express as precisely.

## Change workflow

1. Read `AGENTS.md` and the documents routed by the affected area.
2. Inspect the implementation and identify the authoritative owner of the fact being changed.
3. Make the code change without using documentation to justify behavior the code does not implement.
4. Update the existing owner, or create a focused feature document only when the creation threshold is met.
5. Update the `AGENTS.md` index if a document is added, moved, renamed, or changes scope.
6. Check links, contradictions, duplicated facts, stale paths, and diff scope.
