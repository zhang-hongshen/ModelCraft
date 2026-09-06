# Coding guide

Read this before writing, refactoring, or restructuring ModelCraft code. The default is the simplest implementation that fits the current product and existing ownership model.

## Directness first

- Solve the concrete requirement; do not design for hypothetical future scale, multi-user service workloads, alternate backends, or reuse that does not exist.
- Prefer a direct function call, stored property, local helper, or existing owner over a new abstraction.
- Keep one obvious path for each operation. Do not add fallback paths, duplicate sources of truth, shadow state, or compatibility layers unless the product currently requires them.
- Do not turn a small operation into a subsystem. A cache does not need an orchestration layer merely because it may grow later; a derived value does not need a background task merely because it can be computed asynchronously.

## Ownership and abstraction threshold

Put behavior where its state and lifecycle already live. Before creating a new type, identify what it uniquely owns.

Create a new `Coordinator`, `Manager`, `Service`, protocol, wrapper, adapter, or shared utility only when at least one of these is true:

- it owns a real lifecycle or resource boundary that no existing type owns;
- two or more concrete consumers already require the same contract;
- it isolates an external/platform boundary such as AppKit, filesystem, process, network, persistence, or model runtime;
- the existing owner would otherwise hold unrelated responsibilities.

Do not create one solely to shorten a file, avoid calling an existing type directly, prepare for possible future reuse, or make dependency injection possible.

## Dependencies

- Prefer direct construction and direct references when ownership is local and unambiguous.
- Pass a dependency explicitly only when the caller genuinely owns or selects it, or when the dependency must vary at runtime.
- Do not introduce protocols only for mocking, stylistic decoupling, or single-implementation indirection.
- In SwiftUI, pass narrow values and bindings for local view data. Use the established environment/application owner for genuinely shared state; do not thread services through long initializer chains without a concrete need.
- Do not add containers, registries, factories, locators, or DI frameworks unless the existing product has a demonstrated runtime selection problem they solve.

## Concurrency and derived work

- Prefer synchronous/local derivation when the required value is already available in memory or in the current model/tool result.
- Start a `Task` only for actual asynchronous work or when task ownership/cancellation is required.
- Do not enqueue secondary inference work merely to recover metadata already returned by the primary inference path.
- Preserve a single owner for cancellation and settlement. Avoid detached tasks and parallel state mutation unless the feature requires concurrency.

## Refactoring

- Refactor only as far as needed to make the requested change correct and clear.
- Prefer deleting obsolete indirection over wrapping it in another layer.
- Do not rename, reorganize, or generalize unrelated code while fixing a local issue.
- Reuse an existing abstraction only when its semantics actually match; do not force unrelated behavior through a generic coordinator or service.
- Keep APIs concrete until multiple real call sites demonstrate a stable shared contract.

## Review questions

Before finishing, check:

- Could this be implemented with fewer types, layers, tasks, or state holders?
- Did I add an abstraction for a current requirement or for an imagined future one?
- Is there more than one source of truth for the same state?
- Am I passing dependencies through UI layers that do not own or choose them?
- Am I recomputing or asynchronously querying information already available on the current path?
- Does each new type have a clear responsibility and lifecycle that existing types cannot own cleanly?
