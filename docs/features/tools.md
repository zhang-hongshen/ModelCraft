# Tools

This document owns the Tool feature's model-visible discovery, schemas, execution path, results, failures, and UI presentation. Read it before changing a tool or an agent system prompt that may overlap with Tool-owned knowledge.

## Discovery contract

The model discovers tools from the schemas supplied with each request. The tool schema is the authoritative place for tool-selection knowledge.

**A tool must explain itself.** Its name, description, and parameter descriptions must let a model determine what the tool does, when it is appropriate, what it requires, what it changes, and what it returns.

Never put tool-specific routing in a system prompt. Do not write rules such as “when the user asks for X, call Y,” lists mapping situations to tool names, or hidden sequencing knowledge that only works when the model has read the prompt. System prompts may define general assistant behavior and cross-tool policy; each tool owns its selection and usage contract.

If two tools must be used in sequence, place the prerequisite in the dependent tool's description and make the preceding tool's result expose the input needed for the next call. If an action must be observed before success can be claimed, the action tool itself must say so.

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
3. Expose it through `ToolDefinition.allTools` or an intentional conditional schema path.
4. Dispatch it in `ToolExecutor` when it does not execute through its schema closure.
5. Return a structured `CallToolResult` and a model-facing tool message that faithfully describe the same outcome.
6. Add concise running, completed, and failed presentation in `ToolCall` and a specialized SwiftUI renderer only when the result benefits from one.
7. Preserve the recorded assistant -> tool call -> tool result -> next assistant order in `AgentExecutor` and persistence.

Do not add a system-prompt rule to compensate for an ambiguous schema. Improve the tool description or parameter descriptions instead.

## Results and failures

Return the smallest structured result that supports the next model decision and the UI. Distinguish success from failure explicitly; do not report success before an effect is observable. Error text should name the failed operation and the corrective action available to the model without leaking implementation noise.

Tool output is untrusted external or model-boundary data. Validate at file, process, network, accessibility, decoding, and model/tool JSON boundaries. Do not add redundant validation between typed same-process components.

## Review checklist

- Could a model choose this tool correctly from its schema alone?
- Is every fact needed to construct valid arguments present in parameter descriptions?
- Does the system prompt remain free of tool names and situation-to-tool routing?
- Do schema, input type, execution, returned result, stored message, and UI presentation agree?
- Are side effects, destructive behavior, prerequisites, stale identifiers, and verification steps explicit?
- Does failure leave conversation and persisted tool state complete rather than spinning indefinitely?
