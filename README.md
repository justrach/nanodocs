# nanodocs

A native Markdown (`.md`), HTML (`.html`), and **Mermaid** studio + agent artifact shelf + **MCP server** (Streamable HTTP & stdio) built on [nanoui](https://github.com/justrach/nanoui). No webview: documents and diagrams are parsed once at load time into blocks and ASTs and drawn directly at 120 Hz with Metal and CoreText on macOS (or `nanoui`'s TrueType shaper and OpenGL / CPU renderer on Linux and Windows).

## Features

- **Streamable HTTP & Stdio MCP Server (`http://127.0.0.1:7740/mcp` & `nanodocs mcp`)**:
  - Modeled after Codegraff's MCP server (`mcp_server.zig` / `mcp_server_http.zig` / `mcp_server_modern.zig`), supporting both **stateless `2026-07-28` MCP** (`params._meta`, `server/discover`, `MCP-Protocol-Version`/`Mcp-Method`/`Mcp-Name` header validation) and **session-based `2025-11-25` / `2025-06-18` / `2025-03-26` / `2024-11-05` MCP** (`initialize`, `Mcp-Session-Id`, `DELETE /mcp`).
  - Runs automatically in the background on `http://127.0.0.1:7740/mcp` whenever the `nanodocs` GUI window is open, and wakes the live window via `dispatchMain` as soon as an agent calls `show_document` or `render_mermaid`.
  - Exposes 4 tools: `show_document`, `render_mermaid`, `list_shelf`, and `read_document`.
- **Ultra-Fast Native GPU Mermaid Renderer (0 ms per-frame parse)**: Pre-parses ```` ```mermaid ```` blocks (and `<pre class="mermaid">` in `.html`) into typed ASTs at load time and lays them out natively on the GPU:
  - `flowchart` / `graph` (`TD`, `LR`, `BT`, `RL`) with ranked Sugiyama layout, barycenter ordering, back-edge routing, and shapes (`rect`, `round`, `stadium`, `circle`, `diamond`, `hexagon`, `cylinder`, `subroutine`, `flag`).
  - `sequenceDiagram` with participants, actors, lifelines, solid/dashed arrows, self-loops, `Note over/left of/right of`, and `loop`/`alt`/`opt` sections.
  - `stateDiagram` / `stateDiagram-v2`, `classDiagram`, and `erDiagram`.
  - `pie` charts with proportional distribution bars and percentage legends.
- **Native Markdown + HTML rendering**: ATX and HTML headings, inline **bold**, *italic*, `code` pills, links, GitHub-flavored alerts (`[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`), GFM pipe tables, task lists, collapsible `<details>`, shields.io badges, and embedded PNG/JPEG/GIF images.
- **Liquid Glass floating capsules**: Floating translucent pill controls (`ui.div(c).glass(...)`) over a warm editorial paper canvas (`#fbfaf7` in Paper mode, `#ffffff` in Crisp Light, `#10100f` in Obsidian Dark).
- **Transaction-synced live resize**: Uses `nanoui`'s `c.live_resizing` and retained scroll skirts (`src/ui/retain.zig`) so dragging the window edge stays locked to the cursor at 120 Hz.
- **`.env` Discord & MCP inspector**: Reads `.env` (`DISCORD_GUILD_ID`, `DISCORD_INVITE_URL`, `DISCORD_WEBHOOK_URL`, `NANODOCS_MCP_PORT`, `NANODOCS_MCP_TOKEN`) so server, webhook, and MCP status can be inspected and copied from the top glass capsule.

## Adding `nanodocs` as an MCP Server

```sh
# Print ready-to-paste mcpServers JSON (both Streamable HTTP and stdio):
nanodocs mcp config

# Add to Claude Code over Streamable HTTP:
claude mcp add --transport http nanodocs http://127.0.0.1:7740/mcp

# Or run the standalone HTTP listener yourself (with optional Bearer token):
nanodocs mcp --http --port 7740
```

```json
{
  "mcpServers": {
    "nanodocs": {
      "type": "http",
      "url": "http://127.0.0.1:7740/mcp"
    },
    "nanodocs-stdio": {
      "command": "/path/to/nanodocs",
      "args": ["mcp"]
    }
  }
}
```

## CLI Usage

```sh
# Show a visual walkthrough + Mermaid diagram to the user (writes to .nanoui/shelf/):
nanodocs show --title "Architecture Plan" --markdown $'```mermaid\nflowchart LR\n  Agent([Agent]) --> GPU[[120Hz Metal]]\n```'

# Machine-readable shelf index & agent help:
nanodocs --agent-help
nanodocs --json

# Build & run tests:
zig build
zig build test
```
