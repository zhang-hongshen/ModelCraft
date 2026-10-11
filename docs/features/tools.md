# Tools

This document owns the Tool feature's model-visible discovery, schemas, execution path, results, failures, and UI presentation. Read it before changing a tool or an agent system prompt that may overlap with Tool-owned knowledge.

## Discovery contract

The model discovers tools from the schemas supplied with each request. The tool schema is the authoritative place for tool-selection knowledge.

**A tool must explain itself.** Its name, description, and parameter descriptions must let a model determine what the tool does, when it is appropriate, what it requires, what it changes, and what it returns.

Never put tool-specific routing in a system prompt. Output formats that are not tools, such as [Generative UI](generative-ui.md) blocks, may be described in the system prompt. Do not write rules such as “when the user asks for X, call Y,” lists mapping situations to tool names, or hidden sequencing knowledge that only works when the model has read the prompt. System prompts may define general assistant behavior and cross-tool policy; each tool owns its selection and usage contract.

If two tools must be used in sequence, place the prerequisite in the dependent tool's description and make the preceding tool's result expose the input needed for the next call. If an action must be observed before success can be claimed, the action tool itself must say so.

## Skill discovery

Skills use the open Agent Skills directory format with a required `SKILL.md`. ModelCraft loads bundled skills first, then the standard user directory at `~/.agents/skills`, followed by user-configured directories in settings order. A later directory overrides an earlier skill with the same name.

Only skill names and descriptions appear in the `activate_skill` schema. Activating one skill returns its full instructions and directory so referenced resources remain relative to the skill root. The catalog reloads when its schema is assembled, allowing settings changes and newly created skills to become discoverable without relaunching the app.

The chat slash palette reloads the same catalog and presents functions separately from a labeled Skills section. Skill rows show the metadata name and description. Selecting one inserts an inline `/<skill-name>` token at the current insertion point; a message may contain multiple tokens in any position, and each explicitly requires `activate_skill` before the request is handled.

## Fixed tool set and native applications

`ToolDefinition.allToolSchema(for:)` returns the same tools on every request so the prompt prefix stays reusable; only `search_project` depends on the chat, and a chat's project does not change. Do not add or remove tools based on the user's message, the foreground application, or connectivity; a tool that cannot run reports that in its result.

Every tool is exposed directly under its own name. The native-application tools are `notes_*`, `calendar_*`, `reminders_*`, and `mail_*` in `AppTool`; `run_applescript` is a separate, confirmed long-tail fallback. GUI control is owned by [Computer use](computer-use.md).

Calendar and Reminders use EventKit. Notes and Mail use `AppleScriptRunner.run`, which launches the target application in the background when it is not running and then executes `NSAppleScript` off the main thread. A script error, including Automation denial, is thrown and becomes a failed tool result; denial tells the user where to enable it in System Settings. AppleScript literals assembled from tool arguments must use `AppleScriptLiteral`; interpolating model or user strings directly into source is not allowed.

Additional providers such as Shortcuts or MCP add their schemas to the fixed tool set and dispatch through `ToolExecutor`; provider-specific routing does not belong in the system prompt.

## Schema writing

Use a stable, specific verb-noun name that distinguishes the capability from neighboring tools. Avoid names that describe an implementation rather than the result the model can request.

A tool description must cover, as applicable:

- the observable capability and returned result;
- the situations that distinguish it from similar tools;
- required prior state or a required preceding tool result;
- important limits, unsupported cases, and whether it reads or mutates state;
- side effects, confirmation requirements, or state that becomes stale after execution;
- the next observation required to verify an interaction.

Parameter descriptions must state semantic meaning rather than repeat the parameter name. Include units, coordinate space, accepted values, defaults, path interpretation, freshness requirements, and overwrite behavior wherever they matter. Required parameters represent genuinely required information; optional parameters have a real documented default.

Descriptions are concise operational contracts, not tutorials. Include only information that changes tool selection or argument construction. Put execution details in code and durable cross-feature flow in [Architecture](../architecture.md).

## Implementation surfaces

A tool is complete only when every affected surface agrees:

1. Define its stable name in `Core/Agent/Tools/ToolCall.swift`.
2. Define the schema beside the implementation under `Core/Agent/Tools/`; keep input and output `Codable` types aligned with it.
3. Expose it through `ToolDefinition.allTools`.
4. Dispatch it in `ToolExecutor` when it does not execute through its schema closure.
5. Return a structured `CallToolResult` and a model-facing tool message that faithfully describe the same outcome.
6. Add concise running, completed, and failed presentation in `ToolCall` and a specialized SwiftUI renderer only when the result benefits from one.
7. Preserve the recorded assistant -> tool call -> tool result -> next assistant order in `AgentExecutor` and persistence.

Do not add a system-prompt rule to compensate for an ambiguous schema. Improve the tool description or parameter descriptions instead.

## Results and failures

Return the smallest structured result that supports the next model decision and the UI. Distinguish success from failure explicitly; do not report success before an effect is observable. Error text should name the failed operation and the corrective action available to the model without leaking implementation noise.

Tool output is untrusted external or model-boundary data. Validate at file, process, network, accessibility, decoding, and model/tool JSON boundaries. Do not add redundant validation between typed same-process components.

## User input

`request_user_input` may collect multiple related fields in one tool call. The chat presents one field per page with Back, Skip, and Next (Confirm on the last page), preserves answers while the user moves backward or forward, and returns all answers together after the last page. A skipped field is returned with empty `values`.

## Execution approval

Application approval protects authority boundaries rather than every tool invocation. Observation, search, native-application reads, user-input collection, local media generation, skill activation, pointer movement, scrolling, and strictly recognized read-only commands execute without an application approval prompt. Native-application creates and updates require approval. An `apply_patch` call is validated against the current files before its approval prompt; a patch that cannot apply is returned to the model as a failed result without asking the user. macOS privacy permissions such as Automation, Calendars, Reminders, Accessibility, Screen Recording, and Microphone access remain separate platform requirements.

An approval prompt offers `Deny`, `Allow Once`, and `Always Allow`. `Allow Once` authorizes only the pending execution. `Always Allow` stores the matching authorization in memory for the current conversation; it is not shared with another conversation or persisted across application sessions. A file selected through `request_user_input` authorizes that exact file; a selected directory authorizes the directory and its descendants. Approval of a write authorizes that exact path, approval of a semantic interface action authorizes further interaction with that application, and approval of coordinate interaction authorizes further coordinate interaction. Other approvals are reused only when their complete tool-call signature is unchanged.

`run_applescript` is the exception: every call displays the complete source and requires a fresh decision, so it never offers `Always Allow` (`ToolApprovalRequest.allowsAlways`). A script containing `do shell script` carries a warning because it can execute shell commands with ModelCraft's authority.

Command auto-approval is intentionally strict. A single recognized read-only command without shell control operators, redirection, command substitution, or known mutating options bypasses approval. Narrow `mkdir`, `rm`, and `touch` commands also bypass approval when every target is already inside a user-selected file scope. Ambiguous command strings still require approval.

## Review checklist

- Could a model choose this tool correctly from its schema alone?
- Is every fact needed to construct valid arguments present in parameter descriptions?
- Does the system prompt remain free of tool names and situation-to-tool routing?
- Do schema, input type, execution, returned result, stored message, and UI presentation agree?
- Are side effects, destructive behavior, prerequisites, stale identifiers, and verification steps explicit?
- Does failure leave conversation and persisted tool state complete rather than spinning indefinitely?
