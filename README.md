# nanodocs

A native Markdown (`.md`) and HTML (`.html`) studio and agent artifact shelf built on [nanoui](https://github.com/justrach/nanoui). No webview: documents are parsed into blocks and inline spans and drawn directly with Metal and CoreText on macOS (or `nanoui`'s TrueType shaper and OpenGL / CPU renderer on Linux and Windows).

## Features

- **Native Markdown + HTML rendering**: ATX and HTML headings, inline **bold**, *italic*, `code` pills, links, GitHub-flavored alerts (`[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`), GFM pipe tables, task lists, collapsible `<details>`, shields.io badges, and embedded PNG/JPEG/GIF images.
- **Agent Artifact Shelf (`.nanoui/shelf/`)**: Stores and indexes every `.md` and `.html` report agents generate alongside workspace docs (`README.md`, `AGENTS.md`, `docs/`), with one-click pinning and instant switching (`⌘1`..`⌘9`).
- **Liquid Glass floating capsules**: Floating translucent pill controls (`ui.div(c).glass(...)`) over a warm editorial paper canvas (`#fbfaf7` in Paper mode, `#ffffff` in Crisp Light, `#10100f` in Obsidian Dark).
- **Transaction-synced live resize**: Uses `nanoui`'s `c.live_resizing` and retained scroll skirts (`src/ui/retain.zig`) so dragging the window edge stays locked to the cursor at 120 Hz without re-scanning the filesystem mid-drag.
- **`.env` Discord & Workspace inspector**: Reads `.env` (`DISCORD_GUILD_ID`, `DISCORD_INVITE_URL`, `DISCORD_WEBHOOK_URL`) so server and webhook status can be inspected and copied from the top glass capsule.

## Usage

```sh
zig build run -- README.md
zig build run -- --shelf path/to/agent-report.md
zig build test
```
