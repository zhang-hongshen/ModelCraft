# Connectors

This document owns Connectors: the catalog of Mac apps ModelCraft operates over MCP, the server contract those apps implement, installation, and how their tools join the tool set. Read it before changing `Connector`, `ConnectorTool`, `ConnectorsView`, or an app's MCP server.

## Catalog

`Connector` is a fixed catalog of apps (Arthub, Keel, TuneStudio). Each case names the app's bundle identifier, whether it is sandboxed, its releases page, and the SF Symbol shown while the app is not on this Mac. Adding an app means adding a case; there is no user-entered server.

The sidebar's Connectors page lists the catalog as cards with the app icon, name, and summary. The trailing action is **Get <app>** (opens the releases page) when the app is not installed on this Mac, **Install** when it is, a progress indicator while installing, and an **Installed** menu with **Uninstall** afterwards.

## Server contract

ModelCraft is an MCP client using [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) (`HTTPClientTransport`, non-streaming). Each connector app runs a stateless Streamable HTTP MCP server and must:

- listen only on `127.0.0.1`, on any port;
- require `Authorization: Bearer <token>` on every request, with a random token per server start;
- write `{"url": "http://127.0.0.1:<port>/mcp", "token": "<token>"}` to `<Application Support>/<bundle ID>/mcp.json` each time it starts listening, where Application Support is the app's own (inside its container when sandboxed);
- describe each tool so a model can use it from the schema alone ([Tools](tools.md#schema-writing)), and set `readOnlyHint: true` only on tools that change nothing.

A sandboxed server app needs the incoming network connections entitlement.

## Installation and calls

Installing connects to the app, launching it in the background when it is not running, and stores the complete `tools/list` result at `~/Library/Application Support/ModelCraft/Connectors/<connector>.json`. That file is the installed state; uninstalling deletes it.

`ToolDefinition.allToolSchema(for:)` appends every cached tool as `<connector>__<tool>`, with the description prefixed by the app name, so the tool set changes only when the user installs or uninstalls a connector. `ToolExecutor` routes those names to `ConnectorTool.call`, which opens one connection per call. When the app is not running it is launched, and the call waits up to ten seconds for an endpoint file written after the launch; a stale file is never used. Failures to launch, find the endpoint, or connect become failed tool results that tell the user to update the app and allow connections.

Connector tools require approval unless their cached annotations mark them read-only. The approval detail shows the call's arguments as JSON, and `Always Allow` reuses the exact signature. MCP text, image, audio, embedded-resource, and resource-link content map to `CallToolResult` blocks; the model-facing tool message carries the text and a placeholder for each non-text block.
