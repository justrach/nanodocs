//! `nanodocs`: native GPU Markdown (`.md`), HTML (`.html`), and Mermaid
//! studio + agent artifact shelf built on `nanoui`.
//!
//! Agent CLI:
//!   nanodocs show --title "Architecture" --markdown "```mermaid\nflowchart LR\n A-->B\n```"
//!   nanodocs show --title "Report" path/to/file.md [--no-open]
//!   nanodocs --agent-help
//!   nanodocs --json
const std = @import("std");
const nanoui = @import("nanoui");
const AppState = @import("app.zig").AppState;
const shelf_mod = @import("shelf.zig");

const agent_help_text =
    \\nanodocs — Agent-First Visual Markdown, HTML & Native GPU Mermaid Studio
    \\
    \\COMMANDS FOR AGENTS:
    \\  nanodocs show --title "<Title>" --markdown "<Markdown + Mermaid>" [--no-open]
    \\      Saves an explanation or diagram to .nanoui/shelf/<slug>.md and shows it to the user.
    \\  nanodocs show --title "<Title>" --html "<HTML>" [--no-open]
    \\      Saves an HTML report to .nanoui/shelf/<slug>.html and shows it to the user.
    \\  nanodocs <file.md|file.html> [--shelf] [--dark]
    \\      Opens a file directly (and optionally pins a copy into .nanoui/shelf/).
    \\  nanodocs --json
    \\      Prints JSON metadata of all documents in .nanoui/shelf/ and .env status.
    \\
    \\SUPPORTED NATIVE GPU MERMAID DIAGRAMS (0ms per-frame parse):
    \\  - flowchart TD / LR / BT / RL (rectangles, rounds, stadiums, diamonds, hexagons, cylinders, subroutines)
    \\  - sequenceDiagram (participants, actors, solid/dashed arrows, self-loops, Note over/left/right, loop/alt/opt)
    \\  - stateDiagram / stateDiagram-v2 ([*] start/end, transitions, labels)
    \\  - classDiagram & erDiagram (relations and labels)
    \\  - pie (title + proportional slices)
    \\
;

pub fn main(init: std.process.Init) !void {
    var explicit_file: ?[]const u8 = null;
    var save_to_shelf: bool = false;
    var dark_start: bool = false;
    var is_show_cmd: bool = false;
    var no_open: bool = false;
    var title_arg: []const u8 = "Agent Walkthrough";
    var inline_md: ?[]const u8 = null;
    var inline_html: ?[]const u8 = null;

    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--nanoui-")) continue;
        if (std.mem.eql(u8, arg, "--agent-help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            _ = std.Io.File.stdout().writeStreamingAll(init.io, agent_help_text) catch {};
            return;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            var sh = shelf_mod.Shelf.init(init.gpa, init.io);
            defer sh.deinit();
            sh.reload(null);
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(init.gpa);
            try out.appendSlice(init.gpa, "{\"shelf_dir\":\"");
            try out.appendSlice(init.gpa, sh.env.shelf_dir);
            try out.appendSlice(init.gpa, "\",\"discord_guild_id\":\"");
            try out.appendSlice(init.gpa, sh.env.guild_id);
            try out.appendSlice(init.gpa, "\",\"documents\":[");
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

    _ = try app.newWindow(.{
        .title = "nanodocs — Markdown, Mermaid & Agent Shelf",
        .width = 1120,
        .height = 760,
        .min_width = 680,
        .min_height = 460,
        .title_bar = .hidden,
        .content = .{ .view = .init(&state, AppState.view) },
    });

    try app.run();
}
