//! `nanodocs`: native GPU Markdown (`.md`), HTML (`.html`), and Mermaid
//! studio + agent artifact shelf + MCP server (Streamable HTTP & stdio).
//!
//! MCP Server (after Codegraff's `graff mcp serve --http`):
//!   nanodocs mcp --http [--port 7740] [--token <secret>]
//!   nanodocs mcp
//!   nanodocs mcp config
//!
//! Agent CLI:
//!   nanodocs show --title "Architecture" --markdown "```mermaid\nflowchart LR\n A-->B\n```"
//!   nanodocs --agent-help
//!   nanodocs --json
const std = @import("std");
const nanoui = @import("nanoui");
const AppState = @import("app.zig").AppState;
const shelf_mod = @import("shelf.zig");
const mcp = @import("mcp.zig");
const mcp_http = @import("mcp_http.zig");

const agent_help_text =
    \\nanodocs — Agent-First Visual Markdown, HTML & Native GPU Mermaid Studio + MCP
    \\
    \\MCP SERVER (Streamable HTTP & stdio, 2026-07-28 stateless + 2025-11-25 session):
    \\  nanodocs mcp --http [--port 7740] [--token <token>]
    \\      Starts the loopback Streamable HTTP MCP listener at http://127.0.0.1:7740/mcp
    \\      (also runs automatically in the background whenever the nanodocs GUI window is open).
    \\  nanodocs mcp
    \\      Runs the MCP server over stdio (newline-delimited JSON-RPC).
    \\  nanodocs mcp config
    \\      Prints mcpServers JSON for HTTP and stdio clients (Claude Code, Cursor, Codex, Graff).
    \\  MCP Tools: `show_document`, `render_mermaid`, `list_shelf`, `read_document`
    \\
    \\CLI COMMANDS FOR AGENTS:
    \\  nanodocs show --title "<Title>" --markdown "<Markdown + Mermaid>" [--no-open]
    \\      Saves an explanation or diagram to .nanoui/shelf/<slug>.md and shows it to the user.
    \\  nanodocs show --title "<Title>" --html "<HTML>" [--no-open]
    \\      Saves an HTML report to .nanoui/shelf/<slug>.html and shows it to the user.
    \\  nanodocs <file.md|file.html> [--shelf] [--dark]
    \\      Opens a file directly (and optionally pins a copy into .nanoui/shelf/).
    \\  nanodocs --json
    \\      Prints JSON metadata of all documents in .nanoui/shelf/, MCP URL, and .env status.
    \\
    \\SUPPORTED NATIVE GPU MERMAID DIAGRAMS (0ms per-frame parse):
    \\  - flowchart TD / LR / BT / RL (rectangles, rounds, stadiums, diamonds, hexagons, cylinders, subroutines)
    \\  - sequenceDiagram (participants, actors, solid/dashed arrows, self-loops, Note over/left/right, loop/alt/opt)
    \\  - stateDiagram / stateDiagram-v2 ([*] start/end, transitions, labels)
    \\  - classDiagram & erDiagram (relations and labels)
    \\  - pie (title + proportional slices)
    \\
;

const BgListenerCtx = struct {
    state: *AppState,
    port: u16,
    token: []const u8,

    fn run(self: *BgListenerCtx) void {
        self.state.mcp_listening.store(true, .release);
        const proto: mcp.Server = .{
            .gpa = self.state.gpa,
            .io = self.state.io,
            .on_show = AppState.notifyFromMcp,
            .on_show_ctx = self.state,
        };
        mcp_http.runHttp(self.state.io, self.state.gpa, self.port, self.token, proto) catch {
            self.state.mcp_listening.store(false, .release);
        };
    }
};

pub fn main(init: std.process.Init) !void {
    var explicit_file: ?[]const u8 = null;
    var save_to_shelf: bool = false;
    var dark_start: bool = false;
    var is_show_cmd: bool = false;
    var is_mcp_cmd: bool = false;
    var is_mcp_config: bool = false;
    var mcp_use_http: bool = false;
    var no_mcp_bg: bool = false;
    var has_snapshot_flag: bool = false;
    var no_open: bool = false;
    var mcp_port_override: ?u16 = null;
    var mcp_token_override: ?[]const u8 = null;
    var title_arg: []const u8 = "Agent Walkthrough";
    var inline_md: ?[]const u8 = null;
    var inline_html: ?[]const u8 = null;

    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--nanoui-")) {
            if (std.mem.startsWith(u8, arg, "--nanoui-snapshot")) has_snapshot_flag = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--agent-help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            _ = std.Io.File.stdout().writeStreamingAll(init.io, agent_help_text) catch {};
            return;
        }
        if (std.mem.eql(u8, arg, "mcp") or std.mem.eql(u8, arg, "--mcp")) {
            is_mcp_cmd = true;
            continue;
        }
        if (is_mcp_cmd and std.mem.eql(u8, arg, "serve")) continue;
        if (is_mcp_cmd and std.mem.eql(u8, arg, "config")) {
            is_mcp_config = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--http")) {
            mcp_use_http = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-mcp")) {
            no_mcp_bg = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--port")) {
            if (args.next()) |p| mcp_port_override = std.fmt.parseInt(u16, p, 10) catch 7740;
            continue;
        }
        if (std.mem.eql(u8, arg, "--token")) {
            if (args.next()) |t| mcp_token_override = t;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            var sh = shelf_mod.Shelf.init(init.gpa, init.io);
            defer sh.deinit();
            sh.reload(null);
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(init.gpa);
            const hdr = try std.fmt.allocPrint(
                init.gpa,
                "{{\"shelf_dir\":\"{s}\",\"mcp_http_url\":\"http://127.0.0.1:{d}/mcp\",\"discord_guild_id\":\"{s}\",\"documents\":[",
                .{ sh.env.shelf_dir, sh.env.mcp_port, sh.env.guild_id },
            );
            defer init.gpa.free(hdr);
            try out.appendSlice(init.gpa, hdr);
            for (sh.entries.items, 0..) |e, i| {
                if (i > 0) try out.append(init.gpa, ',');
                const line = try std.fmt.allocPrint(init.gpa, "{{\"name\":\"{s}\",\"path\":\"{s}\",\"in_shelf\":{},\"words\":{d}}}", .{ e.name, e.path, e.in_shelf, e.doc.word_count });
                defer init.gpa.free(line);
                try out.appendSlice(init.gpa, line);
            }
            try out.appendSlice(init.gpa, "]}\n");
            _ = std.Io.File.stdout().writeStreamingAll(init.io, out.items) catch {};
            return;
        }
        if (std.mem.eql(u8, arg, "show")) {
            is_show_cmd = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-open")) {
            no_open = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--title")) {
            if (args.next()) |t| title_arg = t;
            continue;
        }
        if (std.mem.eql(u8, arg, "--markdown") or std.mem.eql(u8, arg, "-m")) {
            if (args.next()) |m| inline_md = m;
            continue;
        }
        if (std.mem.eql(u8, arg, "--html")) {
            if (args.next()) |h| inline_html = h;
            continue;
        }
        if (std.mem.eql(u8, arg, "--shelf")) {
            save_to_shelf = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dark")) {
            dark_start = true;
            continue;
        }
        explicit_file = arg;
    }

    if (is_mcp_cmd) {
        var sh = shelf_mod.Shelf.init(init.gpa, init.io);
        defer sh.deinit();
        sh.reload(null);
        const port = mcp_port_override orelse sh.env.mcp_port;
        const token = mcp_token_override orelse sh.env.mcp_token;
        if (is_mcp_config) {
            var exe_buf: [1024]u8 = undefined;
            const exe = std.process.executablePath(init.io, &exe_buf) catch 0;
            const exe_str = if (exe > 0) exe_buf[0..exe] else "nanodocs";
            const cfg = try std.fmt.allocPrint(
                init.gpa,
                \\{{
                \\  "mcpServers": {{
                \\    "nanodocs": {{
                \\      "type": "http",
                \\      "url": "http://127.0.0.1:{d}/mcp"
                \\    }},
                \\    "nanodocs-stdio": {{
                \\      "command": "{s}",
                \\      "args": ["mcp"]
                \\    }}
                \\  }}
                \\}}
                \\
            ,
                .{ port, exe_str },
            );
            defer init.gpa.free(cfg);
            _ = std.Io.File.stdout().writeStreamingAll(init.io, cfg) catch {};
            return;
        }
        const proto: mcp.Server = .{ .gpa = init.gpa, .io = init.io };
        if (mcp_use_http) {
            const msg = try std.fmt.allocPrint(init.gpa, "nanodocs MCP listening at http://127.0.0.1:{d}/mcp\n", .{port});
            defer init.gpa.free(msg);
            _ = std.Io.File.stderr().writeStreamingAll(init.io, msg) catch {};
            try mcp_http.runHttp(init.io, init.gpa, port, token, proto);
        } else {
            try mcp_http.runStdio(init, proto);
        }
        return;
    }

    if (is_show_cmd or inline_md != null or inline_html != null) {
        var sh = shelf_mod.Shelf.init(init.gpa, init.io);
        defer sh.deinit();
        sh.reload(null);
        var saved_path: ?[]const u8 = null;
        if (inline_md) |m| {
            saved_path = try sh.writeAgentNote(title_arg, m, false);
        } else if (inline_html) |h| {
            saved_path = try sh.writeAgentNote(title_arg, h, true);
        } else if (explicit_file) |f| {
            if (std.Io.Dir.cwd().readFileAlloc(init.io, f, init.gpa, .limited(4 << 20))) |bytes| {
                defer init.gpa.free(bytes);
                saved_path = try sh.saveArtifact(f, bytes);
            } else |_| {}
        }
        if (saved_path) |sp| {
            explicit_file = try init.gpa.dupe(u8, sp);
            const msg = try std.fmt.allocPrint(init.gpa, "{{\"ok\":true,\"path\":\"{s}\",\"title\":\"{s}\"}}\n", .{ sp, title_arg });
            defer init.gpa.free(msg);
            _ = std.Io.File.stdout().writeStreamingAll(init.io, msg) catch {};
        }
        if (no_open) {
            if (explicit_file) |ef| init.gpa.free(ef);
            return;
        }
    }
    defer if ((is_show_cmd or inline_md != null or inline_html != null) and explicit_file != null) {
        init.gpa.free(explicit_file.?);
    };

    const app = try nanoui.App.create(init, .{ .name = "nanodocs" });
    defer app.destroy();

    var state = AppState.init(init.gpa, init.io, explicit_file);
    defer state.deinit();
    if (dark_start) state.mode = .dark;

    if (save_to_shelf) {
        if (explicit_file) |f| {
            if (std.Io.Dir.cwd().readFileAlloc(init.io, f, init.gpa, .limited(4 << 20))) |bytes| {
                defer init.gpa.free(bytes);
                _ = state.shelf.saveArtifact(f, bytes) catch {};
                state.shelf.reload(explicit_file);
            } else |_| {}
        }
    }

    state.window = try app.newWindow(.{
        .title = "nanodocs — Markdown, Mermaid & Agent MCP Studio",
        .width = 1120,
        .height = 760,
        .min_width = 680,
        .min_height = 460,
        .title_bar = .hidden,
        .content = .{ .view = .init(&state, AppState.view) },
    });

    var bg_ctx: BgListenerCtx = .{
        .state = &state,
        .port = mcp_port_override orelse state.shelf.env.mcp_port,
        .token = mcp_token_override orelse state.shelf.env.mcp_token,
    };
    if (!no_mcp_bg and !has_snapshot_flag) {
        if (std.Thread.spawn(.{}, BgListenerCtx.run, .{&bg_ctx})) |th| {
            th.detach();
        } else |_| {}
    }

    try app.run();
}
