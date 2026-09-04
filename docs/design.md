# Design

This document owns ModelCraft's UI and interaction rules. Read it before changing any SwiftUI view, navigation, presentation, visual style, user-facing text, or interaction.

## Product character

ModelCraft should feel like a native Apple-platform application: calm, compact, content-first, and understandable without custom interaction training. Prefer platform conventions over decorative novelty. Reuse established patterns in the neighboring feature before introducing a new component or visual language.

## SwiftUI first

Use native SwiftUI scenes, containers, controls, menus, toolbars, inspectors, sheets, alerts, focus, drag and drop, and scrolling whenever they express the intended behavior. Prefer intrinsic sizing and system placement over fixed popover or panel dimensions.

Use AppKit/UIKit only when SwiftUI lacks the required platform capability. Keep representables and coordinator code in a focused adapter, expose a small SwiftUI-facing API, and prevent platform objects from becoming application state.

Do not recreate a standard control only to change its appearance. Familiar compact actions may be icon-only when the symbol is unambiguous and an accessibility label is present; otherwise include visible text.

## Appearance and color

Every component must be legible and intentional in both Light and Dark appearances, including hover, selection, focus, disabled, loading, success, warning, and failure states.

- Prefer semantic styles such as `.primary`, `.secondary`, `.tint`, materials, and platform backgrounds.
- Use asset-catalog Light/Dark variants for branded or non-semantic colors.
- Do not hardcode a color that assumes a light or dark background.
- Preserve sufficient contrast without adding borders and backgrounds to every surface.
- Treat screenshots in both appearances as visual references, not substitutes for adaptive implementation.

## Layout and hierarchy

Let content, text styles, safe areas, window size, and Dynamic Type determine size. Avoid fixed text frames and duplicated geometry constants. Use spacing and typography to communicate hierarchy before adding containers or decoration.

Factor a section into its own `View` when it has independent identity, state, observation, or meaningful structure. Keep tiny one-use fragments local. Do not hide view identity behind `AnyView` or conditional modifier helpers.

Lists and `ForEach` require stable domain identity. Do not use array offsets, transient UUIDs, or mutable display content as identity. Compute filtering, sorting, and grouping outside row builders when the collection is non-trivial.

## State and data flow

Views render state; services and models own durable behavior. Keep `@State` private and local. Pass narrow immutable values and bindings rather than entire models when a child needs only a few fields.

Use `@Observable` for UI-observed reference models and keep UI-facing models on the main actor unless the project target's isolation setting provides the same guarantee. Derived collections or expensive formatting used during rendering should be cached outside `body` when their inputs do not change every render.

Preserve cancellation and task ownership. A newer chat action must not leave an older generation, metadata task, or loading state active. UI completion follows the owning service's settled state, not an intermediate tool callback.

## Interaction

Every action needs an observable response. Define loading, empty, disabled, error, cancellation, and retry behavior as part of the component, not after the happy path.

Prefer semantic controls and keyboard behavior supplied by SwiftUI. Preserve focus and structural identity across state changes. Use a value inside a modifier to express conditional styling instead of switching between differently typed view branches.

Tool-call presentation must follow persisted conversation order. Visual grouping is allowed only for adjacent items that already belong together; it must not move calls across assistant turns or imply a backend grouping that does not exist.

## Text, localization, and accessibility

All product copy is localizable. Pass SwiftUI string literals directly to localized view initializers; use `LocalizedStringResource` for user-facing values modeled outside a view. Use format styles for dates, numbers, currencies, and lists, and use leading/trailing alignment so layouts adapt to right-to-left languages.

Use semantic text styles instead of fixed font sizes. Allow labels to expand for translation and accessibility sizes. Every meaningful image and icon-only control needs an accessibility label; decorative images must be hidden from accessibility. Maintain logical focus order, keyboard access, control roles, and sufficiently large interaction targets.

## Review checklist

- Does the result use the native SwiftUI component and interaction model available for the job?
- Is any AppKit/UIKit bridge necessary, isolated, and smaller than the missing capability?
- Are Light and Dark appearances correct for every state without hardcoded assumptions?
- Does the layout adapt to window size, longer translations, and accessibility text sizes?
- Are identity, state ownership, observation, cancellation, and loading settlement correct?
- Are user-visible strings localizable and icon-only actions accessible?
- Does chat and tool UI preserve the true persisted event order?
