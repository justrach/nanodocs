//! Native GPU renderer for `nanodocs`: warm paper / obsidian palettes,
//! Liquid Glass floating pill capsules, and rich Markdown/HTML blocks.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const md = @import("markdown.zig");
const shelf_mod = @import("shelf.zig");
const render_mermaid = @import("render_mermaid.zig");

pub const CanvasMode = enum { paper, light, dark };

pub const Palette = struct {
    bg: ui.Color,
    sidebar: ui.Color,
    card: ui.Color,
    code_bg: ui.Color,
    border: ui.Color,
    ink: ui.Color,
    muted: ui.Color,
    accent: ui.Color,
    glass_tint: ui.Color,

    pub fn forMode(mode: CanvasMode) Palette {
        return switch (mode) {
            .paper => .{
                .bg = .hex(0xfbfaf7),
                .sidebar = .hex(0xf3f1eb),
                .card = .hex(0xf6f4ee),
                .code_bg = .hex(0xf1eee6),
                .border = .hex(0xe4dfd6),
                .ink = .hex(0x181715),
                .muted = .hex(0x6b665e),
                .accent = .hex(0x2563eb),
                .glass_tint = .{ .r = 0.99, .g = 0.98, .b = 0.96, .a = 0.72 },
            },
            .light => .{
                .bg = .hex(0xffffff),
                .sidebar = .hex(0xf6f7f9),
                .card = .hex(0xf8f9fb),
                .code_bg = .hex(0xf2f4f7),
                .border = .hex(0xe5e7eb),
                .ink = .hex(0x111317),
                .muted = .hex(0x646872),
                .accent = .hex(0x2563eb),
                .glass_tint = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 0.75 },
            },
            .dark => .{
                .bg = .hex(0x10100f),
                .sidebar = .hex(0x151514),
                .card = .hex(0x181817),
                .code_bg = .hex(0x1b1b1a),
                .border = .hex(0x272624),
                .ink = .hex(0xf3f2ee),
                .muted = .hex(0x949088),
                .accent = .hex(0x60a5fa),
                .glass_tint = .{ .r = 0.12, .g = 0.12, .b = 0.11, .a = 0.70 },
            },
        };
    }
};

pub const ImageCache = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn get(self: *ImageCache, gpa: std.mem.Allocator, io: std.Io, root_dir: []const u8, src: []const u8) ?[]const u8 {
        if (std.mem.startsWith(u8, src, "http://") or std.mem.startsWith(u8, src, "https://")) return null;
        if (self.map.get(src)) |bytes| return if (bytes.len > 0) bytes else null;
        const cwd = std.Io.Dir.cwd();
        const full = if (std.mem.eql(u8, root_dir, "."))
            src
        else
            (std.fmt.allocPrint(gpa, "{s}/{s}", .{ root_dir, src }) catch return null);
        defer if (!std.mem.eql(u8, root_dir, ".")) gpa.free(full);

        const data = cwd.readFileAlloc(io, full, gpa, .limited(8 << 20)) catch {
            const key = gpa.dupe(u8, src) catch return null;
            self.map.put(gpa, key, "") catch {};
            return null;
        };
        const key = gpa.dupe(u8, src) catch {
            gpa.free(data);
            return null;
        };
        self.map.put(gpa, key, data) catch {};
        return data;
    }

    pub fn deinit(self: *ImageCache, gpa: std.mem.Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            if (kv.value_ptr.*.len > 0) gpa.free(kv.value_ptr.*);
        }
        self.map.deinit(gpa);
    }
};

pub fn renderDocument(
    c: *ui.Context,
    doc: md.Document,
    raw: []const u8,
    show_raw: bool,
    pal: Palette,
    images: *ImageCache,
    gpa: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    live_resizing: bool,
    content_width: f32,
) void {
    ui.column(c, .{
        .width = .fill,
        .align_items = .center,
        .padding = .{ .top = 24, .bottom = 64, .left = 20, .right = 20 },
    });
    defer ui.end(c);

    ui.column(c, .{
        .width = .{ .px = content_width },
        .gap = 14,
    });
    defer ui.end(c);

    if (show_raw) {
        renderCodeBlock(c, if (doc.is_html) "html" else "markdown", raw, pal, 99999);
        return;
    }

    for (doc.blocks, 0..) |b, idx| {
        ui.keyInt(c, idx);
        renderBlock(c, b, idx, pal, images, gpa, io, root_dir, live_resizing, content_width);
    }
}

fn renderBlock(
    c: *ui.Context,
    b: md.Block,
    idx: usize,
    pal: Palette,
    images: *ImageCache,
    gpa: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    live_resizing: bool,
    content_width: f32,
) void {
    switch (b) {
        .heading => |h| {
            const top_pad: f32 = switch (h.level) {
                1 => if (idx == 0) 4 else 18,
                2 => 16,
                else => 10,
            };
            const sz: f32 = switch (h.level) {
                1 => 28,
                2 => 20,
                3 => 16,
                else => 14,
            };
            ui.column(c, .{
                .width = .fill,
                .align_items = if (h.centered) .center else .start,
                .padding = .{ .top = top_pad, .bottom = if (h.level <= 2) 6 else 2 },
                .gap = 8,
            });
            defer ui.end(c);
            ui.text(c, h.text, .{
                .size = sz,
                .weight = .bold,
                .color = pal.ink,
                .wrap = true,
            });
            if (h.level <= 2 and !h.centered) {
                ui.row(c, .{ .width = .fill, .height = .{ .px = 1 }, .background = pal.border });
                ui.end(c);
            }
        },
        .paragraph => |p| {
            ui.column(c, .{
                .width = .fill,
                .align_items = if (p.centered) .center else .start,
            });
            defer ui.end(c);
            ui.richText(c, p.rich.text, p.rich.spans, .{
                .size = if (p.muted) 12.5 else 14.5,
                .line_height = 22,
                .color = if (p.muted) pal.muted else pal.ink,
                .wrap = true,
            });
        },
        .badges => |badges| {
            ui.row(c, .{
                .width = .fill,
                .justify = .center,
                .align_items = .center,
                .gap = 6,
                .padding = .{ .top = 2, .bottom = 4 },
            });
            defer ui.end(c);
            for (badges, 0..) |bd, bi| {
                ui.keyInt(c, bi);
                ui.row(c, .{
                    .radius = 6,
                    .border = pal.border,
                    .border_width = 1,
                    .background = pal.card,
                    .align_items = .center,
                });
                defer ui.end(c);
                ui.row(c, .{ .padding = .{ .left = 6, .right = 5, .top = 2, .bottom = 2 } });
                ui.text(c, bd.label, .{ .size = 10.5, .weight = .medium, .color = pal.muted });
                ui.end(c);
                if (bd.value.len > 0) {
                    ui.row(c, .{
                        .radius = 5,
                        .background = bd.color,
                        .padding = .{ .left = 5, .right = 6, .top = 2, .bottom = 2 },
                    });
                    ui.text(c, bd.value, .{ .size = 10.5, .weight = .semibold, .color = .hex(0xffffff) });
                    ui.end(c);
                }
            }
        },
        .code => |code| renderCodeBlock(c, code.lang, code.text, pal, idx),
        .mermaid => |m| renderMermaidBlock(c, m.source, m.diagram, pal, idx, content_width),
        .callout => |ca| renderCallout(c, ca.kind, ca.title, ca.rich, pal, content_width),
        .list_item => |li| {
            const indent = @as(f32, @floatFromInt(li.depth)) * 16.0;
            const marker_w: f32 = if (li.ordered > 0) 22 else 14;
            const text_w = @max(80, content_width - indent - marker_w - 8);
            ui.row(c, .{
                .width = .fill,
                .gap = 8,
                .padding = .{ .left = indent },
                .align_items = .start,
            });
            defer ui.end(c);
            const marker = if (li.checked) |chk|
                (if (chk) "☑" else "☐")
            else if (li.ordered > 0)
                c.print("{d}.", .{li.ordered})
            else
                "•";
            ui.column(c, .{ .width = .{ .px = marker_w } });
            ui.text(c, marker, .{
                .size = 14,
                .weight = .semibold,
                .color = if (li.checked != null and li.checked.?) pal.accent else pal.muted,
            });
            ui.end(c);
            ui.column(c, .{ .width = .{ .px = text_w } });
            defer ui.end(c);
            ui.richText(c, li.rich.text, li.rich.spans, .{
                .size = 14.5,
                .line_height = 21,
                .color = pal.ink,
                .wrap = true,
            });
        },
        .table => |tbl| renderTable(c, tbl.headers, tbl.rows, pal, content_width),
        .image => |im| {
            if (!live_resizing) {
                if (images.get(gpa, io, root_dir, im.src)) |bytes| {
                    ui.column(c, .{
                        .width = .fill,
                        .align_items = if (im.centered) .center else .start,
                        .padding = .{ .top = 6, .bottom = 6 },
                    });
                    defer ui.end(c);
                    _ = ui.image(c, .{
                        .key = im.src,
                        .source = .{ .encoded = bytes },
                        .max_width = @min(im.width, content_width - 20),
                        .max_height = 420,
                        .radius = 10,
                    });
                    return;
                }
            }
            if (im.alt.len > 0) {
                ui.row(c, .{
                    .width = .fill,
                    .padding = .all(10),
                    .radius = 8,
                    .background = pal.card,
                    .border = pal.border,
                    .border_width = 1,
                });
                defer ui.end(c);
                ui.text(c, c.print("🖼 {s} ({s})", .{ im.alt, im.src }), .{ .size = 12, .color = pal.muted });
            }
        },
        .details => |det| {
            ui.column(c, .{
                .width = .fill,
                .padding = .all(14),
                .radius = 10,
                .background = pal.card,
                .border = pal.border,
                .border_width = 1,
                .gap = 10,
            });
            defer ui.end(c);
            ui.text(c, c.print("▾ {s}", .{det.summary}), .{
                .size = 13.5,
                .weight = .semibold,
                .color = pal.ink,
            });
            for (det.body, 0..) |inner_b, bi| {
                ui.keyInt(c, bi);
                renderBlock(c, inner_b, bi, pal, images, gpa, io, root_dir, live_resizing, content_width - 28);
            }
        },
        .rule => {
            ui.row(c, .{
                .width = .fill,
                .height = .{ .px = 1 },
                .background = pal.border,
            });
            ui.end(c);
        },
    }
}

fn renderCodeBlock(c: *ui.Context, lang: []const u8, code_text: []const u8, pal: Palette, idx: usize) void {
    ui.column(c, .{
        .width = .fill,
        .radius = 10,
        .background = pal.code_bg,
        .border = pal.border,
        .border_width = 1,
    });
    defer ui.end(c);

    ui.row(c, .{
        .width = .fill,
        .padding = .{ .left = 12, .right = 10, .top = 6, .bottom = 6 },
        .align_items = .center,
    });
    ui.text(c, if (lang.len > 0) lang else "code", .{ .size = 11, .weight = .semibold, .color = pal.muted, .mono = true });
    ui.spacer(c);
    const copy_id = c.print("copy-code-{d}", .{idx});
    ui.key(c, copy_id);
    const cp = ui.pressable(c, .{
        .padding = .{ .left = 8, .right = 8, .top = 2, .bottom = 2 },
        .radius = 5,
        .background = pal.card,
    }, pal.border);
    ui.text(c, "Copy", .{ .size = 11, .weight = .medium, .color = pal.muted });
    ui.end(c);
    if (cp.clicked) {
        c.clipboard.write(c.clipboard.ctx, code_text);
    }
    ui.end(c);

    ui.row(c, .{ .width = .fill, .height = .{ .px = 1 }, .background = pal.border });
    ui.end(c);

    ui.column(c, .{ .width = .fill, .padding = .all(12) });
    defer ui.end(c);
    ui.text(c, code_text, .{
        .size = 12.5,
        .line_height = 19,
        .mono = true,
        .color = pal.ink,
        .wrap = true,
    });
}

fn renderMermaidBlock(c: *ui.Context, source: []const u8, diagram: @import("mermaid.zig").Diagram, pal: Palette, idx: usize, content_width: f32) void {
    ui.column(c, .{
        .width = .fill,
        .radius = 12,
        .background = pal.card,
        .border = pal.border,
        .border_width = 1,
    });
    defer ui.end(c);

    // Header bar
    ui.row(c, .{
        .width = .fill,
        .padding = .{ .left = 12, .right = 10, .top = 7, .bottom = 7 },
        .align_items = .center,
        .gap = 8,
    });
    ui.row(c, .{
        .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 },
        .radius = 4,
        .background = pal.accent,
    });
    ui.text(c, "MERMAID", .{ .size = 9.5, .weight = .bold, .color = .hex(0xffffff) });
    ui.end(c);
    ui.text(c, render_mermaid.kindLabel(diagram), .{ .size = 11, .weight = .semibold, .color = pal.muted, .mono = true });
    ui.spacer(c);
    if (content_width >= 520) {
        ui.text(c, "Native GPU", .{ .size = 10.5, .color = pal.muted });
    }
    const copy_id = c.print("copy-mermaid-{d}", .{idx});
    ui.key(c, copy_id);
    const cp = ui.pressable(c, .{
        .padding = .{ .left = 8, .right = 8, .top = 2, .bottom = 2 },
        .radius = 5,
        .background = pal.code_bg,
    }, pal.border);
    ui.text(c, "Copy", .{ .size = 11, .weight = .medium, .color = pal.muted });
    ui.end(c);
    if (cp.clicked) {
        c.clipboard.write(c.clipboard.ctx, source);
    }
    ui.end(c);

    ui.row(c, .{ .width = .fill, .height = .{ .px = 1 }, .background = pal.border });
    ui.end(c);

    // Diagram canvas
    ui.column(c, .{ .width = .fill, .padding = .{ .top = 16, .bottom = 16, .left = 14, .right = 14 } });
    defer ui.end(c);
    const room = @max(content_width - 36, 300);
    if (!render_mermaid.draw(c, diagram, room, pal)) {
        ui.text(c, source, .{ .size = 12, .mono = true, .color = pal.ink, .wrap = true });
    }
}

fn renderCallout(c: *ui.Context, kind: md.AlertKind, title: []const u8, body: ui.markdown.Rich, pal: Palette, content_width: f32) void {
    const accent: ui.Color = switch (kind) {
        .blockquote => pal.muted,
        .note => .hex(0x2563eb),
        .tip => .hex(0x16a34a),
        .important => .hex(0x9333ea),
        .warning => .hex(0xd97706),
        .caution => .hex(0xdc2626),
    };
    ui.row(c, .{
        .width = .fill,
        .radius = 10,
        .background = pal.card,
        .border = pal.border,
        .border_width = 1,
    });
    defer ui.end(c);
    ui.row(c, .{ .width = .{ .px = 4 }, .height = .fill, .radius = 4, .background = accent });
    ui.end(c);
    ui.column(c, .{ .width = .{ .px = @max(80, content_width - 4) }, .padding = .all(12), .gap = 4 });
    defer ui.end(c);
    if (title.len > 0) {
        ui.text(c, title, .{ .size = 12.5, .weight = .bold, .color = accent });
    }
    ui.richText(c, body.text, body.spans, .{
        .size = 13.5,
        .line_height = 20,
        .color = pal.ink,
        .wrap = true,
    });
}

fn colGrow(col_idx: usize, num_cols: usize) f32 {
    if (num_cols == 3) {
        return switch (col_idx) {
            0 => 1.0,
            1 => 1.35,
            else => 2.15,
        };
    }
    return 1.0;
}

fn renderTable(c: *ui.Context, headers: []const []const u8, rows: []const []const md.Cell, pal: Palette, content_width: f32) void {
    const num_cols = if (headers.len > 0) headers.len else if (rows.len > 0) rows[0].len else 1;
    var total_grow: f32 = 0;
    for (0..num_cols) |ci| total_grow += colGrow(ci, num_cols);
    if (total_grow <= 0) total_grow = 1;
    const row_inner_w = @max(120, content_width - 24 - 12 * @as(f32, @floatFromInt(num_cols -| 1)));

    ui.column(c, .{
        .width = .fill,
        .radius = 10,
        .border = pal.border,
        .border_width = 1,
        .background = pal.card,
    });
    defer ui.end(c);

    if (headers.len > 0) {
        ui.row(c, .{
            .width = .fill,
            .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 },
            .gap = 12,
        });
        for (headers, 0..) |h, ci| {
            const col_w = @max(36, @floor(row_inner_w * colGrow(ci, num_cols) / total_grow));
            ui.column(c, .{ .width = .{ .px = col_w } });
            ui.text(c, h, .{ .size = 12, .weight = .bold, .color = pal.ink, .wrap = true });
            ui.end(c);
        }
        ui.end(c);
    }

    for (rows, 0..) |r, ri| {
        ui.keyInt(c, ri);
        if (headers.len > 0 or ri > 0) {
            ui.row(c, .{ .width = .fill, .height = .{ .px = 1 }, .background = pal.border });
            ui.end(c);
        }
        ui.row(c, .{
            .width = .fill,
            .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 },
            .gap = 12,
        });
        for (r, 0..) |cell, ci| {
            const col_w = @max(36, @floor(row_inner_w * colGrow(ci, num_cols) / total_grow));
            ui.column(c, .{ .width = .{ .px = col_w } });
            ui.richText(c, cell.rich.text, cell.rich.spans, .{ .size = 12.5, .color = pal.ink, .wrap = true });
            ui.end(c);
        }
        ui.end(c);
    }
}

pub fn glassPill(c: *ui.Context, pal: Palette) ui.Div {
    return ui.div(c)
        .row()
        .itemsCenter()
        .gap(6)
        .px(10)
        .py(5)
        .roundedFull()
        .bg(pal.card)
        .border(pal.border)
        .borderW(1);
}
