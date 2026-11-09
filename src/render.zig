//! Native GPU renderer for `nanodocs`: warm paper / obsidian palettes,
//! Liquid Glass floating pill capsules, and rich Markdown/HTML blocks.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const md = @import("markdown.zig");
const shelf_mod = @import("shelf.zig");

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
) void {
    ui.column(c, .{
        .width = .fill,
        .align_items = .center,
        .padding = .{ .top = 28, .bottom = 64, .left = 32, .right = 32 },
    });
    defer ui.end(c);

    ui.column(c, .{
        .width = .{ .px = 700 },
        .gap = 14,
    });
    defer ui.end(c);

    if (show_raw) {
        renderCodeBlock(c, if (doc.is_html) "html" else "markdown", raw, pal, 99999);
        return;
    }

    for (doc.blocks, 0..) |b, idx| {
        ui.keyInt(c, idx);
        renderBlock(c, b, idx, pal, images, gpa, io, root_dir, live_resizing);
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
            ui.text(c, md.stripInline(c.alloc(), h.text), .{
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
            ui.markdown.view(c, p.text, .{
                .size = if (p.muted) 12.5 else 14.5,
                .line_height = 22,
                .color = if (p.muted) pal.muted else pal.ink,
                .wrap = true,
            }, .{
                .code_background = pal.code_bg,
                .code_color = pal.ink,
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
                    .clip = true,
                });
                defer ui.end(c);
                ui.row(c, .{ .padding = .{ .left = 6, .right = 5, .top = 2, .bottom = 2 } });
                ui.text(c, bd.label, .{ .size = 10.5, .weight = .medium, .color = pal.muted });
                ui.end(c);
                if (bd.value.len > 0) {
                    ui.row(c, .{
                        .background = bd.color,
                        .padding = .{ .left = 5, .right = 6, .top = 2, .bottom = 2 },
                    });
                    ui.text(c, bd.value, .{ .size = 10.5, .weight = .semibold, .color = .hex(0xffffff) });
                    ui.end(c);
                }
            }
        },
        .code => |code| renderCodeBlock(c, code.lang, code.text, pal, idx),
        .callout => |ca| renderCallout(c, ca.kind, ca.title, ca.text, pal),
        .list_item => |li| {
            ui.row(c, .{
                .width = .fill,
                .gap = 8,
                .padding = .{ .left = @as(f32, @floatFromInt(li.depth)) * 16.0 },
                .align_items = .start,
            });
            defer ui.end(c);
            const marker = if (li.checked) |chk|
                (if (chk) "☑" else "☐")
            else if (li.ordered > 0)
                c.print("{d}.", .{li.ordered})
            else
                "•";
            ui.text(c, marker, .{
                .size = 14,
                .weight = .semibold,
                .color = if (li.checked != null and li.checked.?) pal.accent else pal.muted,
            });
            ui.column(c, .{ .grow = 1 });
            defer ui.end(c);
            ui.markdown.view(c, li.text, .{
                .size = 14.5,
                .line_height = 21,
                .color = pal.ink,
                .wrap = true,
            }, .{
                .code_background = pal.code_bg,
                .code_color = pal.ink,
            });
        },
        .table => |tbl| renderTable(c, tbl.headers, tbl.rows, pal),
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
                        .max_width = @min(im.width, 640),
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
            ui.text(c, c.print("▾ {s}", .{md.stripInline(c.alloc(), det.summary)}), .{
                .size = 13.5,
                .weight = .semibold,
                .color = pal.ink,
            });
            for (det.body, 0..) |inner_b, bi| {
                ui.keyInt(c, bi);
                renderBlock(c, inner_b, bi, pal, images, gpa, io, root_dir, live_resizing);
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
        .clip = true,
    });
    defer ui.end(c);

    ui.row(c, .{
        .width = .fill,
        .padding = .{ .left = 12, .right = 10, .top = 6, .bottom = 6 },
        .align_items = .center,
        .border = pal.border,
        .border_width = 1,
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

fn renderCallout(c: *ui.Context, kind: md.AlertKind, title: []const u8, body: []const u8, pal: Palette) void {
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
        .clip = true,
    });
    defer ui.end(c);
    ui.row(c, .{ .width = .{ .px = 4 }, .height = .fill, .background = accent });
    ui.end(c);
    ui.column(c, .{ .grow = 1, .padding = .all(12), .gap = 4 });
    defer ui.end(c);
    if (title.len > 0) {
        ui.text(c, title, .{ .size = 12.5, .weight = .bold, .color = accent });
    }
    ui.markdown.view(c, body, .{
        .size = 13.5,
        .line_height = 20,
        .color = pal.ink,
        .wrap = true,
    }, .{ .code_background = pal.code_bg, .code_color = pal.ink });
}

fn renderTable(c: *ui.Context, headers: []const []const u8, rows: []const []const md.Cell, pal: Palette) void {
    ui.column(c, .{
        .width = .fill,
        .radius = 10,
        .border = pal.border,
        .border_width = 1,
        .background = pal.card,
        .clip = true,
    });
    defer ui.end(c);

    if (headers.len > 0) {
        ui.row(c, .{
            .width = .fill,
            .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 },
            .background = pal.code_bg,
            .gap = 12,
        });
        for (headers) |h| {
            ui.column(c, .{ .grow = 1, .width = .{ .px = 0 } });
            ui.text(c, md.stripInline(c.alloc(), h), .{ .size = 12, .weight = .bold, .color = pal.ink, .wrap = true });
            ui.end(c);
        }
        ui.end(c);
    }

    for (rows, 0..) |r, ri| {
        ui.keyInt(c, ri);
        ui.row(c, .{
            .width = .fill,
            .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 },
            .border = pal.border,
            .border_width = 1,
            .gap = 12,
        });
        for (r) |cell| {
            ui.column(c, .{ .grow = 1, .width = .{ .px = 0 } });
            ui.markdown.view(c, cell.text, .{ .size = 12.5, .color = pal.ink, .wrap = true }, .{ .code_background = pal.code_bg });
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
        .border(pal.border)
        .borderW(1)
        .glass(.{
            .style = .regular,
            .tint = pal.glass_tint,
            .blur = 10,
        });
}
