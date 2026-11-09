//! Live Markdown + Mermaid split editor and bidirectional Human ↔ Agent
//! feedback inbox (`.nanoui/shelf/inbox.jsonl`).
//!
//! When the user edits a document in `Split` or `Edit` mode, `EditorState`
//! re-parses the Markdown + Mermaid AST in an arena on each edit (~10 µs) so
//! the 120 Hz Metal preview updates live on every keystroke.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const md = @import("markdown.zig");
const render = @import("render.zig");
const shelf_mod = @import("shelf.zig");

pub const ViewMode = enum {
    rendered,
    split,
    source,

    pub fn next(self: ViewMode) ViewMode {
        return switch (self) {
            .rendered => .split,
            .split => .source,
            .source => .rendered,
        };
    }

    pub fn label(self: ViewMode) []const u8 {
        return switch (self) {
            .rendered => "Rendered",
            .split => "Split Edit",
            .source => "Source",
        };
    }
};

pub const EditorState = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    buf: ui.TextBuffer = .{},
    reply_buf: ui.TextBuffer = .{},
    loaded_index: ?usize = null,
    loaded_name_buf: [128]u8 = undefined,
    loaded_name_len: usize = 0,
    dirty: bool = false,
    live_arenas: [4]?std.heap.ArenaAllocator = .{ null, null, null, null },
    arena_slot: u2 = 0,
    live_doc: ?md.Document = null,
    live_raw: ?[]const u8 = null,
    last_feedback_status: []const u8 = "",

    pub fn init(gpa: std.mem.Allocator, io: std.Io) EditorState {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *EditorState) void {
        for (&self.live_arenas) |*slot| {
            if (slot.*) |*a| a.deinit();
        }
        self.buf.deinit();
        self.reply_buf.deinit();
    }

    /// Synchronizes the editor buffer when the user switches documents.
    pub fn syncDocument(self: *EditorState, index: usize, entry: shelf_mod.Entry) void {
        const name = entry.name;
        const prev_name = self.loaded_name_buf[0..self.loaded_name_len];
        if (self.loaded_index == index and std.mem.eql(u8, prev_name, name)) return;

        self.loaded_index = index;
        const n = @min(name.len, self.loaded_name_buf.len);
        @memcpy(self.loaded_name_buf[0..n], name[0..n]);
        self.loaded_name_len = n;
        self.buf.set(entry.raw);
        self.dirty = false;
        self.live_doc = null;
        self.live_raw = null;
    }

    pub fn forceReload(self: *EditorState, index: usize, entry: shelf_mod.Entry) void {
        self.loaded_index = null;
        self.syncDocument(index, entry);
    }

    /// Re-parses the live buffer into a `md.Document` + Mermaid ASTs in the next
    /// ring-buffer arena slot so previous passes' slices remain valid throughout
    /// multi-pass `ui.frame.run` rebuilds.
    pub fn reparse(self: *EditorState, is_html: bool) void {
        self.arena_slot +%= 1;
        const slot = &self.live_arenas[self.arena_slot];
        if (slot.*) |*a| {
            _ = a.reset(.retain_capacity);
        } else {
            slot.* = .init(self.gpa);
        }
        const a = slot.*.?.allocator();
        const raw_copy = a.dupe(u8, self.buf.text()) catch return;
        self.live_raw = raw_copy;
        self.live_doc = md.parse(a, raw_copy, is_html);
    }

    pub fn activeDoc(self: *const EditorState, fallback: md.Document) md.Document {
        return self.live_doc orelse fallback;
    }

    pub fn activeRaw(self: *const EditorState, fallback: []const u8) []const u8 {
        return self.live_raw orelse fallback;
    }

    /// Saves the edited buffer back to the file on disk (or `.nanoui/shelf/`).
    pub fn saveCurrent(self: *EditorState, shelf: *shelf_mod.Shelf, index: usize) ?[]const u8 {
        if (shelf.entries.items.len == 0) return null;
        const idx = @min(index, shelf.entries.items.len - 1);
        const ent = shelf.entries.items[idx];
        const content = self.buf.text();
        const cwd = std.Io.Dir.cwd();
        // Write directly to `ent.path` if writable, otherwise `.nanoui/shelf/`
        if (cwd.createFile(self.io, ent.path, .{ .truncate = true })) |f| {
            defer f.close(self.io);
            f.writeStreamingAll(self.io, content) catch {};
            self.dirty = false;
            return ent.path;
        } else |_| {
            const saved = shelf.saveArtifact(ent.name, content) catch return null;
            self.dirty = false;
            return saved;
        }
    }

    /// Renders the live Markdown + Mermaid editor column with quick-insert tools.
    pub fn renderEditorPane(
        self: *EditorState,
        c: *ui.Context,
        pal: render.Palette,
        shelf: *shelf_mod.Shelf,
        selected: usize,
        width: f32,
        on_toast: *[]const u8,
    ) void {
        const is_html = if (shelf.entries.items.len > 0)
            shelf.entries.items[@min(selected, shelf.entries.items.len - 1)].is_html
        else
            false;

        ui.column(c, .{
            .width = .{ .px = width },
            .height = .fill,
            .padding = .{ .top = 14, .bottom = 14, .left = 16, .right = 16 },
            .gap = 10,
            .background = pal.sidebar,
            .border = pal.border,
            .border_width = 1,
        });
        defer ui.end(c);

        // Quick-insert & Save toolbar
        ui.row(c, .{ .width = .fill, .align_items = .center, .gap = 6 });
        ui.text(c, if (self.dirty) "LIVE EDITOR ●" else "LIVE EDITOR", .{
            .size = 10.5,
            .weight = .bold,
            .color = if (self.dirty) pal.accent else pal.muted,
        });
        ui.spacer(c);

        if (snippetBtn(c, pal, "ins-flow", "+ Flowchart")) {
            _ = self.buf.insert(self.buf.text().len, "\n```mermaid\nflowchart LR\n  Human([User Edit]) -->|live 120Hz| GPU[[Metal Preview]]\n```\n");
            self.dirty = true;
            self.reparse(is_html);
            c.changed = true;
        }
        if (snippetBtn(c, pal, "ins-seq", "+ Sequence")) {
            _ = self.buf.insert(self.buf.text().len, "\n```mermaid\nsequenceDiagram\n  participant U as User\n  participant A as Agent\n  U->>A: Edited in nanodocs\n```\n");
            self.dirty = true;
            self.reparse(is_html);
            c.changed = true;
        }
        if (snippetBtn(c, pal, "ins-tip", "+ Callout")) {
            _ = self.buf.insert(self.buf.text().len, "\n> [!TIP]\n> Live note added in nanodocs editor.\n");
            self.dirty = true;
            self.reparse(is_html);
            c.changed = true;
        }

        ui.key(c, "btn-save-doc");
        const save_btn = ui.pressable(c, .{
            .padding = .{ .left = 9, .right = 9, .top = 3, .bottom = 3 },
            .radius = 6,
            .background = if (self.dirty) pal.accent else pal.code_bg,
        }, pal.accent);
        ui.text(c, "Save ⌘S", .{
            .size = 11,
            .weight = .semibold,
            .color = if (self.dirty) .hex(0xffffff) else pal.ink,
        });
        ui.end(c);
        if (save_btn.clicked) {
            if (self.saveCurrent(shelf, selected)) |_| {
                on_toast.* = "✓ Saved edits";
                c.changed = true;
            }
        }
        ui.end(c);

        // Multiline monospace Markdown/Mermaid editor
        ui.scroll(c, .{
            .width = .fill,
            .grow = 1,
            .radius = 8,
            .background = pal.card,
            .border = pal.border,
            .border_width = 1,
            .padding = .all(6),
        });
        defer ui.end(c);

        ui.key(c, "markdown-live-editor");
        const ed = ui.textField(c, &self.buf, .{
            .width = .{ .px = @max(width - 48, 180) },
            .multiline = true,
            .max_lines = 400,
            .mono = true,
            .size = 12.5,
            .line_height = 19,
            .bare = true,
            .color = pal.ink,
            .placeholder = "Type Markdown or ```mermaid diagrams here…",
        });
        if (ed.submitted) {
            const n = self.buf.insert(ed.caret, "\n");
            self.buf.want_caret = ed.caret + n;
            self.dirty = true;
            self.reparse(is_html);
            c.changed = true;
        } else if (ed.changed) {
            self.dirty = true;
            self.reparse(is_html);
            c.changed = true;
        }
    }

    /// Renders the bottom Human → Agent feedback & annotation bar.
    pub fn renderAgentCommsBar(
        self: *EditorState,
        c: *ui.Context,
        pal: render.Palette,
        shelf: *shelf_mod.Shelf,
        selected: usize,
        pane_w: f32,
        on_toast: *[]const u8,
    ) void {
        const compact = pane_w < 760;
        ui.row(c, .{
            .width = .fill,
            .padding = .{ .top = 8, .bottom = 10, .left = if (compact) 12 else 20, .right = if (compact) 12 else 20 },
            .align_items = .center,
            .gap = 8,
            .background = pal.sidebar,
            .border = pal.border,
            .border_width = 1,
        });
        defer ui.end(c);

        const doc_name = if (shelf.entries.items.len > 0)
            shelf.entries.items[@min(selected, shelf.entries.items.len - 1)].name
        else
            "untitled.md";

        const field_w = @max(pane_w - (if (compact) @as(f32, 230) else 340), 140);
        ui.key(c, "agent-reply-input");
        const rep = ui.textField(c, &self.reply_buf, .{
            .width = .{ .px = field_w },
            .size = 12.5,
            .color = pal.ink,
            .placeholder = if (compact) "Reply or annotate for Agent…" else "Reply to Agent or annotate this doc (saved to .nanoui/shelf/inbox.jsonl)…",
        });

        ui.key(c, "btn-agent-send");
        const send_btn = ui.pressable(c, .{
            .padding = .{ .left = 10, .right = 10, .top = 5, .bottom = 5 },
            .radius = 7,
            .background = pal.code_bg,
        }, pal.border);
        ui.text(c, "Send ↵", .{ .size = 11.5, .weight = .semibold, .color = pal.ink });
        ui.end(c);

        ui.key(c, "btn-agent-changes");
        const chg_btn = ui.pressable(c, .{
            .padding = .{ .left = 10, .right = 10, .top = 5, .bottom = 5 },
            .radius = 7,
            .background = pal.code_bg,
        }, pal.border);
        ui.text(c, if (compact) "✎ Revise" else "✎ Request Changes", .{ .size = 11.5, .weight = .semibold, .color = .hex(0xd97706) });
        ui.end(c);

        ui.key(c, "btn-agent-approve");
        const app_btn = ui.pressable(c, .{
            .padding = .{ .left = 10, .right = 10, .top = 5, .bottom = 5 },
            .radius = 7,
            .background = .hex(0x16a34a),
        }, .hex(0x15803d));
        ui.text(c, if (compact) "✓ Approve" else "✓ Approve Plan", .{ .size = 11.5, .weight = .bold, .color = .hex(0xffffff) });
        ui.end(c);

        const submit_status: ?[]const u8 = if (app_btn.clicked)
            "approved"
        else if (chg_btn.clicked)
            "changes_requested"
        else if (send_btn.clicked or rep.submitted)
            "comment"
        else
            null;

        if (submit_status) |st| {
            if (self.dirty) _ = self.saveCurrent(shelf, selected);
            const msg = if (self.reply_buf.text().len > 0)
                self.reply_buf.text()
            else if (std.mem.eql(u8, st, "approved"))
                "Approved in nanodocs."
            else
                "Changes requested in nanodocs.";
            appendInbox(self.gpa, self.io, shelf.root_dir, doc_name, st, msg, self.dirty);
            self.reply_buf.clear();
            self.last_feedback_status = st;
            on_toast.* = if (std.mem.eql(u8, st, "approved")) "✓ Sent Approval" else "✓ Sent to Agent Inbox";
            c.changed = true;
        }
    }
};

fn snippetBtn(c: *ui.Context, pal: render.Palette, key_id: []const u8, label_str: []const u8) bool {
    ui.key(c, key_id);
    const b = ui.pressable(c, .{
        .padding = .{ .left = 7, .right = 7, .top = 3, .bottom = 3 },
        .radius = 6,
        .background = pal.code_bg,
    }, pal.border);
    ui.text(c, label_str, .{ .size = 11, .weight = .medium, .color = pal.ink });
    ui.end(c);
    return b.clicked;
}

/// Appends one JSONL feedback event to `.nanoui/shelf/inbox.jsonl`.
pub fn appendInbox(
    gpa: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    doc_name: []const u8,
    status: []const u8,
    message: []const u8,
    edited: bool,
) void {
    const cwd = std.Io.Dir.cwd();
    const dir_path = if (std.mem.eql(u8, root_dir, "."))
        ".nanoui/shelf"
    else
        (std.fmt.allocPrint(gpa, "{s}/.nanoui/shelf", .{root_dir}) catch return);
    defer if (!std.mem.eql(u8, root_dir, ".")) gpa.free(dir_path);

    cwd.createDirPath(io, dir_path) catch {};
    const inbox_path = std.fmt.allocPrint(gpa, "{s}/inbox.jsonl", .{dir_path}) catch return;
    defer gpa.free(inbox_path);

    const existing = cwd.readFileAlloc(io, inbox_path, gpa, .limited(2 << 20)) catch gpa.dupe(u8, "") catch return;
    defer gpa.free(existing);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    if (existing.len > 0) {
        aw.writer.writeAll(existing) catch return;
        if (existing[existing.len - 1] != '\n') aw.writer.writeByte('\n') catch return;
    }
    aw.writer.writeAll("{\"doc\":") catch return;
    writeJsonStr(&aw.writer, doc_name) catch return;
    aw.writer.writeAll(",\"status\":") catch return;
    writeJsonStr(&aw.writer, status) catch return;
    aw.writer.writeAll(",\"edited\":") catch return;
    aw.writer.writeAll(if (edited) "true" else "false") catch return;
    aw.writer.writeAll(",\"message\":") catch return;
    writeJsonStr(&aw.writer, message) catch return;
    aw.writer.writeAll("}\n") catch return;

    const f = cwd.createFile(io, inbox_path, .{ .truncate = true }) catch return;
    defer f.close(io);
    f.writeStreamingAll(io, aw.written()) catch {};
}

/// Reads `.nanoui/shelf/inbox.jsonl` (returns caller-owned slice).
pub fn readInboxAlloc(gpa: std.mem.Allocator, io: std.Io, root_dir: []const u8) []const u8 {
    const cwd = std.Io.Dir.cwd();
    const inbox_path = if (std.mem.eql(u8, root_dir, "."))
        gpa.dupe(u8, ".nanoui/shelf/inbox.jsonl") catch return gpa.dupe(u8, "") catch ""
    else
        std.fmt.allocPrint(gpa, "{s}/.nanoui/shelf/inbox.jsonl", .{root_dir}) catch return gpa.dupe(u8, "") catch "";
    defer gpa.free(inbox_path);

    return cwd.readFileAlloc(io, inbox_path, gpa, .limited(2 << 20)) catch (gpa.dupe(u8, "") catch "");
}

fn writeJsonStr(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (ch >= 0x20) try w.writeByte(ch),
    };
    try w.writeByte('"');
}
