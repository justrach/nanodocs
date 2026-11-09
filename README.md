# nanodocs

A native Markdown (`.md`), HTML (`.html`), and **Mermaid** studio + agent artifact shelf built on [nanoui](https://github.com/justrach/nanoui). No webview: documents and diagrams are parsed once at load time into blocks and ASTs and drawn directly at 120 Hz with Metal and CoreText on macOS (or `nanoui`'s TrueType shaper and OpenGL / CPU renderer on Linux and Windows).

## Features

- **Ultra-Fast Native GPU Mermaid Renderer (0 ms per-frame parse)**: Pre-parses ```` ```mermaid ```` blocks (and `<pre class="mermaid">` in `.html`) into typed ASTs at load time and lays them out natively on the GPU:
  - `flowchart` / `graph` (`TD`, `LR`, `BT`, `RL`) with ranked Sugiyama layout, barycenter ordering, back-edge routing, and shapes (`rect`, `round`, `stadium`, `circle`, `diamond`, `hexagon`, `cylinder`, `subroutine`, `flag`).
  - `sequenceDiagram` with participants, actors, lifelines, solid/dashed arrows, self-loops, `Note over/left of/right of`, and `loop`/`alt`/`opt` sections.
  - `stateDiagram` / `stateDiagram-v2`, `classDiagram`, and `erDiagram`.
  - `pie` charts with proportional distribution bars and percentage legends.
- **Agent-First Workflow (`nanodocs show`)**: Coding agents can push visual walkthroughs, architecture diagrams, and HTML verification reports straight to `.nanoui/shelf/` and surface them to the user with a single command (`nanodocs show --title "..." --markdown "..."`). When `nanodocs` is already open, it detects changes in `.nanoui/shelf/` automatically.
- **Native Markdown + HTML rendering**: ATX and HTML headings, inline **bold**, *italic*, `code` pills, links, GitHub-flavored alerts (`[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`), GFM pipe tables, task lists, collapsible `<details>`, shields.io badges, and embedded PNG/JPEG/GIF images.
- **Liquid Glass floating capsules**: Floating translucent pill controls (`ui.div(c).glass(...)`) over a warm editorial paper canvas (`#fbfaf7` in Paper mode, `#ffffff` in Crisp Light, `#10100f` in Obsidian Dark).
- **Transaction-synced live resize**: Uses `nanoui`'s `c.live_resizing` and retained scroll skirts (`src/ui/retain.zig`) so dragging the window edge stays locked to the cursor at 120 Hz.
- **`.env` Discord & Workspace inspector**: Reads `.env` (`DISCORD_GUILD_ID`, `DISCORD_INVITE_URL`, `DISCORD_WEBHOOK_URL`) so server and webhook status can be inspected and copied from the top glass capsule.

## Agent & CLI Usage

```sh
# Show a visual walkthrough + Mermaid diagram to the user (writes to .nanoui/shelf/):
nanodocs show --title "Architecture Plan" --markdown $'```mermaid\nflowchart LR\n  Agent([Agent]) --> GPU[[120Hz Metal]]\n```'

# Save to .nanoui/shelf/ without opening a window (if nanodocs is already open):
nanodocs show --title "Verification Report" --markdown "..." --no-open

# Machine-readable shelf index & agent help:
nanodocs --agent-help
nanodocs --json

# Build & run tests:
zig build
zig build test
```
