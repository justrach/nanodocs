//! Agent Artifact Shelf (`.nanoui/shelf/`) and `.env` workspace configuration.
//!
//! Stores and indexes `.md` and `.html` documents produced by agents alongside
//! repository docs (`README.md`, `AGENTS.md`, `docs/`), watches `.nanoui/shelf/`
//! for live agent pushes, and reads `.env` so the Discord community server and
//! webhook can be inspected from the UI.
const std = @import("std");
const md = @import("markdown.zig");

pub const EnvConfig = struct {
    guild_id: []const u8 = "",
    invite_url: []const u8 = "https://discord.gg/EmTpv7rmTA",
    webhook_url: []const u8 = "",
    shelf_dir: []const u8 = ".nanoui/shelf",
    mcp_port: u16 = 7740,
    mcp_url: []const u8 = "http://127.0.0.1:7740/mcp",
    mcp_token: []const u8 = "",
    loaded_from: []const u8 = "",
};

pub const Entry = struct {
    name: []const u8,
    path: []const u8,
    raw: []const u8,
    is_html: bool,
    in_shelf: bool,
    doc: md.Document,
};

pub const Shelf = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,
    env: EnvConfig = .{},
    root_dir: []const u8 = ".",
    shelf_digest: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Shelf {
        return .{
            .gpa = gpa,
            .io = io,
            .arena = .init(gpa),
        };
    }

    pub fn deinit(self: *Shelf) void {
        self.entries.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn reload(self: *Shelf, explicit_file: ?[]const u8) void {
        self.entries.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();

        const cwd = std.Io.Dir.cwd();
        self.root_dir = if (cwd.statFile(self.io, "src/nanoui.zig", .{})) |_|
            "."
        else |_| if (cwd.statFile(self.io, "../../src/nanoui.zig", .{})) |_|
            "../.."
        else |_|
            ".";

        self.loadEnv(a);
        self.ensureShelfSeeded(a);

        if (explicit_file) |f| {
            self.addFile(a, f, std.mem.indexOf(u8, f, "shelf") != null);
        }

        // Scan `.nanoui/shelf` first so agent walkthroughs & diagrams are immediately accessible
        const shelf_path = self.shelfDirPath(a);
        if (std.fmt.allocPrint(a, "{s}/agent-architecture-walkthrough.md", .{shelf_path})) |walkthrough_path| {
            self.addFile(a, walkthrough_path, true);
        } else |_| {}
        if (cwd.openDir(self.io, shelf_path, .{ .iterate = true })) |dir_val| {
            var dir = dir_val;
            defer dir.close(self.io);
            var it = dir.iterate();
            while (it.next(self.io) catch null) |ent| {
                if (ent.kind != .file) continue;
                if (!std.mem.endsWith(u8, ent.name, ".md") and !std.mem.endsWith(u8, ent.name, ".html")) continue;
                const full = std.fmt.allocPrint(a, "{s}/{s}", .{ shelf_path, ent.name }) catch continue;
                self.addFile(a, full, true);
            }
        } else |_| {}

        // Standard workspace documents
        const candidates = [_][]const u8{
            "README.md",
            "AGENTS.md",
            "apps/nanodocs/README.md",
            "apps/nanoterm/README.md",
            "apps/nanomon/README.md",
            "apps/nanobrowser/README.md",
        };
        for (candidates) |rel| {
            const full = if (std.mem.eql(u8, self.root_dir, "."))
                rel
            else
                (std.fmt.allocPrint(a, "{s}/{s}", .{ self.root_dir, rel }) catch continue);
            self.addFile(a, full, false);
        }

        self.shelf_digest = self.computeShelfDigest();
    }

    pub fn shelfDirPath(self: *const Shelf, a: std.mem.Allocator) []const u8 {
        return if (std.mem.eql(u8, self.root_dir, "."))
            self.env.shelf_dir
        else
            (std.fmt.allocPrint(a, "{s}/{s}", .{ self.root_dir, self.env.shelf_dir }) catch self.env.shelf_dir);
    }

    /// Computes a lightweight hash of filenames and byte sizes in `.nanoui/shelf/`
    /// so `nanodocs` hot-reloads whenever an agent writes or updates an artifact.
    pub fn computeShelfDigest(self: *const Shelf) u64 {
        var buf: [512]u8 = undefined;
        const shelf_path = if (std.mem.eql(u8, self.root_dir, "."))
            self.env.shelf_dir
        else
            (std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.root_dir, self.env.shelf_dir }) catch return 0);

        const cwd = std.Io.Dir.cwd();
        var dir = cwd.openDir(self.io, shelf_path, .{ .iterate = true }) catch return 0;
        defer dir.close(self.io);

        var h = std.hash.Wyhash.init(0);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |ent| {
            if (ent.kind != .file) continue;
            h.update(ent.name);
            if (dir.statFile(self.io, ent.name, .{})) |st| {
                h.update(std.mem.asBytes(&st.size));
            } else |_| {}
        }
        return h.final();
    }

    pub fn loadEnv(self: *Shelf, a: std.mem.Allocator) void {
        const cwd = std.Io.Dir.cwd();
        const paths = [_][]const u8{ ".env", "../../.env" };
        for (paths) |p| {
            const bytes = cwd.readFileAlloc(self.io, p, a, .limited(64 * 1024)) catch continue;
            self.env = parseEnvBytes(bytes, p);
            return;
        }
    }

    fn ensureShelfSeeded(self: *Shelf, a: std.mem.Allocator) void {
        const cwd = std.Io.Dir.cwd();
        const shelf_path = self.shelfDirPath(a);
        cwd.createDirPath(self.io, shelf_path) catch return;

        const mm_sample = std.fmt.allocPrint(a, "{s}/agent-architecture-walkthrough.md", .{shelf_path}) catch return;
        if (cwd.statFile(self.io, mm_sample, .{}) == error.FileNotFound) {
            cwd.writeFile(self.io, .{
                .sub_path = mm_sample,
                .data =
                \\# Agent Visual Walkthrough & Native Mermaid Studio
                \\
                \\Coding agents can push visual explanations, architecture diagrams, verification proofs, and HTML reports straight to the user with **`nanodocs show`** — rendered at **120 Hz on Metal/GPU** with **0 ms per-frame Mermaid parsing**.
                \\
                \\> [!TIP]
                \\> Run `nanodocs show --title "Architecture Plan" --markdown "..."` or drop any `.md` / `.html` into `.nanoui/shelf/` and `nanodocs` hot-reloads it live.
                \\
                \\## 1. Agent-to-User Visual Loop (`flowchart`)
                \\
                \\```mermaid
                \\flowchart LR
                \\  Agent([Coding Agent]) -->|nanodocs show| Shelf[(.nanoui/shelf)]
                \\  Shelf -->|Pre-parse AST| Check{Diagram Kind?}
                \\  Check -->|Flow / State| Sugiyama[Ranked Sugiyama Layout]
                \\  Check -->|Sequence| Lifelines[Participant Lifelines]
                \\  Check -->|Pie| Stacked[Proportional Bar]
                \\  Sugiyama --> GPU[[120Hz Metal GPU Frame]]
                \\  Lifelines --> GPU
                \\  Stacked --> GPU
                \\```
                \\
                \\## 2. Live Resize & Precompiled Runtime (`sequenceDiagram`)
                \\
                \\```mermaid
                \\sequenceDiagram
                \\  participant User as Developer
                \\  participant Agent as Coding Agent
                \\  participant Shelf as .nanoui/shelf
                \\  participant GPU as nanodocs (Metal)
                \\  Agent->>Shelf: nanodocs show --title "Plan"
                \\  Note over Shelf,GPU: File watcher detects new artifact & pre-parses Mermaid AST once
                \\  Shelf->>GPU: Load Document + Mermaid AST
                \\  GPU-->>User: Instant 120Hz visual walkthrough
                \\  User->>GPU: Drag window corner (c.live_resizing)
                \\  GPU-->>User: Zero-jitter transaction-synced frame
                \\```
                \\
                \\## 3. Formal Surface Lifecycle (`stateDiagram-v2`)
                \\
                \\Verified in Lean 4 (`lean-proofs/NanoUI/SurfaceLifecycle.lean`) with zero `sorry`s:
                \\
                \\```mermaid
                \\stateDiagram-v2
                \\  [*] --> Active
                \\  Active --> InFrame : displayLink / event
                \\  InFrame --> Active : frame complete
                \\  InFrame --> ClosingInFrame : window.close() inside handler
                \\  ClosingInFrame --> Swept : autorelease + alive(tok) guard
                \\  Active --> Swept : App.destroy()
                \\  Swept --> [*]
                \\```
                \\
                \\## 4. Incremental Rebuild Breakdown (`pie`)
                \\
                \\With precompiled **`libnanoui-rt.a`** (`src/rt.zig`), a 1-line edit rebuilds in **0.56 s** instead of **2.2 s**:
                \\
                \\```mermaid
                \\pie title 1-Line Edit Rebuild Time (0.56 s total)
                \\  "App Zig Codegen" : 52
                \\  "Cached libnanoui-rt.a Link" : 30
                \\  "Mach-O & Ad-Hoc Sign" : 18
                \\```
                ,
            }) catch {};
        }

        const html_sample = std.fmt.allocPrint(a, "{s}/agent-launch-report.html", .{shelf_path}) catch return;
        cwd.writeFile(self.io, .{
            .sub_path = html_sample,
            .data =
            \\<!DOCTYPE html>
            \\<html>
            \\<head><title>Agent Verification & Launch Report</title></head>
            \\<body>
            \\<h1>Agent Verification &amp; Launch Report</h1>
            \\<p>Generated automatically into <code>.nanoui/shelf/</code> for instant native GPU inspection without opening a browser.</p>
            \\<h2>1. Native Mermaid in HTML</h2>
            \\<pre class="mermaid">
            \\flowchart LR
            \\  PRs([47 Open PRs]) --> Audit{Security Audit}
            \\  Audit -->|Clean| Merge[Merged to main]
            \\  Merge --> Lean[[5 Lean 4 Proofs]]
            \\</pre>
            \\<h2>2. Formal Verification (Lean 4)</h2>
            \\<ul>
            \\  <li><strong>NanoUI.SurfaceLifecycle</strong>: Proves zero use-after-free during in-frame window close and post-frame event guards (Issue #108).</li>
            \\  <li><strong>NanoUI.LiveResize</strong>: Proves WindowServer transaction quiescence after <code>resize_hold_s</code> (120 ms) and immediate stop on <code>viewDidEndLiveResize</code>.</li>
            \\  <li><strong>NanoUI.RetainedScroll</strong>: Proves shift translation equivalence and full-width hit preservation across right-aligned buttons (Issue #115).</li>
            \\  <li><strong>NanoUI.BuildSplit</strong>: Proves precompiled <code>libnanoui-rt.a</code> strictly lowers 1-line-edit rebuild cost (<code>0.56 s</code> vs <code>2.2 s</code>).</li>
            \\</ul>
            \\</body>
            \\</html>
            ,
        }) catch {};
    }

    pub fn saveArtifact(self: *Shelf, filename: []const u8, contents: []const u8) ![]const u8 {
        const a = self.arena.allocator();
        const cwd = std.Io.Dir.cwd();
        const shelf_path = self.shelfDirPath(a);
        try cwd.createDirPath(self.io, shelf_path);
        const dest = try std.fmt.allocPrint(a, "{s}/{s}", .{ shelf_path, std.fs.path.basename(filename) });
        try cwd.writeFile(self.io, .{ .sub_path = dest, .data = contents });
        return dest;
    }

    pub fn writeAgentNote(self: *Shelf, title: []const u8, contents: []const u8, is_html: bool) ![]const u8 {
        const a = self.arena.allocator();
        var slug: std.ArrayList(u8) = .empty;
        for (title) |ch| {
            if (std.ascii.isAlphanumeric(ch)) {
                try slug.append(a, std.ascii.toLower(ch));
            } else if (slug.items.len > 0 and slug.items[slug.items.len - 1] != '-') {
                try slug.append(a, '-');
            }
        }
        const clean_slug = std.mem.trim(u8, slug.items, "-");
        const base = if (clean_slug.len > 0) clean_slug else "agent-note";
        const ext = if (is_html) "html" else "md";
        const filename = try std.fmt.allocPrint(a, "{s}.{s}", .{ base, ext });
        const body = if (!is_html and !std.mem.startsWith(u8, std.mem.trimStart(u8, contents, " \t\r\n"), "#"))
            try std.fmt.allocPrint(a, "# {s}\n\n{s}\n", .{ title, contents })
        else
            contents;
        return self.saveArtifact(filename, body);
    }

    fn addFile(self: *Shelf, a: std.mem.Allocator, path: []const u8, in_shelf: bool) void {
        const base = std.fs.path.basename(path);
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.path, path) or (e.in_shelf == in_shelf and std.mem.eql(u8, e.name, base))) return;
        }
        const raw = std.Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(4 << 20)) catch return;
        const is_html = std.mem.endsWith(u8, path, ".html") or std.mem.endsWith(u8, path, ".htm");
        const doc = md.parse(a, raw, is_html);
        self.entries.append(self.gpa, .{
            .name = a.dupe(u8, base) catch base,
            .path = a.dupe(u8, path) catch path,
            .raw = raw,
            .is_html = is_html,
            .in_shelf = in_shelf,
            .doc = doc,
        }) catch {};
    }
};

pub fn parseEnvBytes(bytes: []const u8, source_name: []const u8) EnvConfig {
    var cfg: EnvConfig = .{ .loaded_from = source_name };
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t\"'");
        if (std.mem.eql(u8, key, "DISCORD_GUILD_ID")) {
            cfg.guild_id = val;
        } else if (std.mem.eql(u8, key, "DISCORD_INVITE_URL")) {
            cfg.invite_url = val;
        } else if (std.mem.eql(u8, key, "DISCORD_WEBHOOK_URL")) {
            cfg.webhook_url = val;
        } else if (std.mem.eql(u8, key, "NANOUI_SHELF_DIR")) {
            cfg.shelf_dir = val;
        } else if (std.mem.eql(u8, key, "NANODOCS_MCP_PORT")) {
            cfg.mcp_port = std.fmt.parseInt(u16, val, 10) catch 7740;
        } else if (std.mem.eql(u8, key, "NANODOCS_MCP_URL")) {
            cfg.mcp_url = val;
        } else if (std.mem.eql(u8, key, "NANODOCS_MCP_TOKEN")) {
            cfg.mcp_token = val;
        }
    }
    return cfg;
}
