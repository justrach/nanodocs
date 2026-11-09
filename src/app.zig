//! `nanodocs` window and UI state: sidebar shelf + outline, floating Liquid
//! Glass top capsules, `.env` Discord server inspector, and `c.live_resizing`
//! transaction-synced resize handling.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const md = @import("markdown.zig");
const shelf_mod = @import("shelf.zig");
const render = @import("render.zig");

pub const AppState = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    shelf: shelf_mod.Shelf,
    images: render.ImageCache = .{},
    selected: usize = 0,
    mode: render.CanvasMode = .paper,
    show_sidebar: bool = true,
    show_raw: bool = false,
    show_env_panel: bool = false,
    show_mcp_panel: bool = false,
    was_resizing: bool = false,
    status_toast: []const u8 = "",
    explicit_file: ?[]const u8 = null,
    window: ?*nanoui.Window = null,
    mcp_listening: std.atomic.Value(bool) = .init(false),
    mcp_dirty: std.atomic.Value(bool) = .init(false),
    mcp_calls: std.atomic.Value(u64) = .init(0),

    pub fn init(gpa: std.mem.Allocator, io: std.Io, explicit_file: ?[]const u8) AppState {
        var s: AppState = .{
            .gpa = gpa,
            .io = io,
            .shelf = .init(gpa, io),
            .explicit_file = explicit_file,
        };
        s.shelf.reload(explicit_file);
        return s;
    }

    pub fn deinit(self: *AppState) void {
        self.images.deinit(self.gpa);
        self.shelf.deinit();
    }

    pub fn view(self: *AppState, c: *ui.Context) void {
        // Live-resize lesson from nanoterm: while the window is inside a
        // WindowServer resize transaction (`c.live_resizing`), keep the frame
        // lightweight; once the drag ends, rebuild once to settle assets.
        if (self.was_resizing and !c.live_resizing) {
            c.changed = true;
        }
        self.was_resizing = c.live_resizing;

        // Zero-syscall frame path: only reload `.nanoui/shelf/` when an incoming
        // MCP call marks `mcp_dirty` (or the user presses Cmd+R).
        if (!c.live_resizing and self.mcp_dirty.swap(false, .acquire)) {
            self.shelf.reload(self.explicit_file);
            self.selected = 0;
            c.changed = true;
        }

        // Keyboard shortcuts
        if (c.shortcut(.{ .key = 't', .cmd = true })) {
            self.mode = switch (self.mode) {
                .paper => .dark,
                .dark => .light,
                .light => .paper,
            };
        }
        if (c.shortcut(.{ .key = 'b', .cmd = true })) self.show_sidebar = !self.show_sidebar;
        if (c.shortcut(.{ .key = 'e', .cmd = true })) self.show_raw = !self.show_raw;
        if (c.shortcut(.{ .key = 'd', .cmd = true })) self.show_env_panel = !self.show_env_panel;
        if (c.shortcut(.{ .key = 'm', .cmd = true })) self.show_mcp_panel = !self.show_mcp_panel;
        if (c.shortcut(.{ .key = 'r', .cmd = true }) and !c.live_resizing) {
            self.shelf.reload(self.explicit_file);
        }
        inline for (0..9) |i| {
            if (c.shortcut(.{ .key = '1' + i, .cmd = true })) {
                if (i < self.shelf.entries.items.len) self.selected = i;
            }
        }

        const pal = render.Palette.forMode(self.mode);

        ui.row(c, .{
            .width = .fill,
            .height = .fill,
            .background = pal.bg,
        });
        defer ui.end(c);

        if (self.show_sidebar) {
            self.renderSidebar(c, pal);
        }

        ui.column(c, .{
            .grow = 1,
            .height = .fill,
            .background = pal.bg,
        });
        defer ui.end(c);

        self.renderTopGlassBar(c, pal);

        if (self.show_mcp_panel) {
            self.renderMcpPanel(c, pal);
        }
        if (self.show_env_panel) {
            self.renderEnvPanel(c, pal);
        }

        if (self.shelf.entries.items.len == 0) {
            ui.column(c, .{ .width = .fill, .grow = 1, .align_items = .center, .justify = .center });
            ui.text(c, "No Markdown or HTML documents found.", .{ .size = 15, .color = pal.muted });
            ui.end(c);
            return;
        }

        const idx = @min(self.selected, self.shelf.entries.items.len - 1);
        const active = self.shelf.entries.items[idx];

        ui.scroll(c, .{
            .width = .fill,
            .grow = 1,
        });
        defer ui.end(c);

        render.renderDocument(
            c,
            active.doc,
            active.raw,
            self.show_raw,
            pal,
            &self.images,
            self.gpa,
            self.io,
            self.shelf.root_dir,
            c.live_resizing,
        );
    }

    fn renderSidebar(self: *AppState, c: *ui.Context, pal: render.Palette) void {
        ui.column(c, .{
            .width = .{ .px = 248 },
            .height = .fill,
            .background = pal.sidebar,
            .border = pal.border,
            .border_width = 1,
            .padding = .{ .top = 42, .bottom = 14, .left = 12, .right = 12 },
            .gap = 12,
        });
        defer ui.end(c);

        // Brand header
        ui.row(c, .{ .width = .fill, .align_items = .center, .gap = 8, .padding = .{ .left = 4, .right = 4 } });
        ui.text(c, "nanodocs", .{ .size = 14, .weight = .bold, .color = pal.ink });
        ui.spacer(c);
        ui.row(c, .{
            .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 },
            .radius = 999,
            .background = pal.code_bg,
        });
        ui.text(c, c.print("{d} docs", .{self.shelf.entries.items.len}), .{ .size = 10.5, .weight = .semibold, .color = pal.muted });
        ui.end(c);
        ui.end(c);

        // Workspace & Agent Shelf list
        ui.text(c, "WORKSPACE & AGENT SHELF", .{ .size = 10, .weight = .bold, .color = pal.muted });

        ui.column(c, .{ .width = .fill, .gap = 3 });
        for (self.shelf.entries.items, 0..) |ent, i| {
            ui.keyInt(c, i);
            const active = i == self.selected;
            const row_id = c.print("shelf-item-{d}", .{i});
            ui.key(c, row_id);
            const hit = ui.pressable(c, .{
                .width = .fill,
                .padding = .{ .left = 8, .right = 8, .top = 6, .bottom = 6 },
                .radius = 7,
                .background = if (active) pal.code_bg else .transparent,
            }, pal.code_bg);
            ui.row(c, .{ .width = .fill, .align_items = .center, .gap = 6 });
            ui.row(c, .{
                .padding = .{ .left = 5, .right = 5, .top = 1, .bottom = 1 },
                .radius = 4,
                .background = if (ent.is_html) .hex(0xd97706) else pal.accent,
            });
            ui.text(c, if (ent.is_html) "HTML" else "MD", .{ .size = 9, .weight = .bold, .color = .hex(0xffffff) });
            ui.end(c);
            ui.text(c, ent.name, .{
                .size = 12.5,
                .weight = if (active) .semibold else .regular,
                .color = if (active) pal.ink else pal.muted,
                .truncate = .ellipsis,
            });
            ui.spacer(c);
            if (ent.in_shelf) {
                ui.text(c, "shelf", .{ .size = 10, .color = pal.muted });
            }
            ui.end(c);
            ui.end(c);
            if (hit.clicked) {
                self.selected = i;
                c.changed = true;
            }
        }
        ui.end(c);

        // Outline of active document
        if (self.shelf.entries.items.len > 0) {
            const active = self.shelf.entries.items[@min(self.selected, self.shelf.entries.items.len - 1)];
            if (active.doc.outline.len > 0) {
                ui.row(c, .{ .width = .fill, .height = .{ .px = 1 }, .background = pal.border });
                ui.end(c);
                ui.text(c, "OUTLINE", .{ .size = 10, .weight = .bold, .color = pal.muted });
                ui.scroll(c, .{ .width = .fill, .grow = 1 });
                ui.column(c, .{ .width = .fill, .gap = 4 });
                for (active.doc.outline, 0..) |h, hi| {
                    ui.keyInt(c, hi);
                    ui.row(c, .{
                        .width = .fill,
                        .padding = .{ .left = @as(f32, @floatFromInt(h.level -| 1)) * 10.0 + 4.0, .top = 2, .bottom = 2 },
                    });
                    ui.text(c, h.text, .{
                        .size = if (h.level == 1) 12 else 11.5,
                        .weight = if (h.level == 1) .semibold else .regular,
                        .color = if (h.level == 1) pal.ink else pal.muted,
                        .truncate = .ellipsis,
                    });
                    ui.end(c);
                }
                ui.end(c);
                ui.end(c);
            }
        }
    }

    fn renderTopGlassBar(self: *AppState, c: *ui.Context, pal: render.Palette) void {
        ui.row(c, .{
            .width = .fill,
            .padding = .{ .top = 12, .bottom = 10, .left = 20, .right = 20 },
            .align_items = .center,
            .gap = 10,
            .border = pal.border,
            .border_width = 1,
        });
        defer ui.end(c);

        // Left Liquid Glass capsule: sidebar toggle + active file + word count
        {
            const left = render.glassPill(c, pal);
            defer left.end();
            ui.key(c, "toggle-sidebar");
            const sb_btn = ui.pressable(c, .{
                .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 },
                .radius = 999,
            }, pal.code_bg);
            ui.text(c, if (self.show_sidebar) "◧" else "▭", .{ .size = 12, .weight = .bold, .color = pal.ink });
            ui.end(c);
            if (sb_btn.clicked) {
                self.show_sidebar = !self.show_sidebar;
                c.changed = true;
            }

            if (self.shelf.entries.items.len > 0) {
                const active = self.shelf.entries.items[@min(self.selected, self.shelf.entries.items.len - 1)];
                ui.text(c, active.name, .{ .size = 12.5, .weight = .semibold, .color = pal.ink });
                ui.text(c, "·", .{ .size = 12, .color = pal.muted });
                ui.text(c, c.print("{d} words", .{active.doc.word_count}), .{ .size = 11.5, .color = pal.muted });
            }
            if (c.live_resizing) {
                ui.row(c, .{
                    .padding = .{ .left = 6, .right = 6, .top = 1, .bottom = 1 },
                    .radius = 999,
                    .background = pal.accent,
                });
                ui.text(c, "120Hz Resize", .{ .size = 10, .weight = .bold, .color = .hex(0xffffff) });
                ui.end(c);
            }
        }

        ui.spacer(c);

        // Right Liquid Glass capsule: Rendered/Source, Paper/Light/Dark, Pin to Shelf, Discord .env
        {
            const right = render.glassPill(c, pal);
            defer right.end();
            ui.key(c, "btn-raw");
            const raw_btn = ui.pressable(c, .{
                .padding = .{ .left = 8, .right = 8, .top = 3, .bottom = 3 },
                .radius = 999,
                .background = if (self.show_raw) pal.code_bg else .transparent,
            }, pal.code_bg);
            ui.text(c, if (self.show_raw) "Source" else "Rendered", .{ .size = 11.5, .weight = .medium, .color = pal.ink });
            ui.end(c);
            if (raw_btn.clicked) {
                self.show_raw = !self.show_raw;
                c.changed = true;
            }

            const mode_label = switch (self.mode) {
                .paper => "Paper",
                .light => "Light",
                .dark => "Dark",
            };
            ui.key(c, "btn-mode");
            const mode_btn = ui.pressable(c, .{
                .padding = .{ .left = 8, .right = 8, .top = 3, .bottom = 3 },
                .radius = 999,
                .background = pal.code_bg,
            }, pal.border);
            ui.text(c, mode_label, .{ .size = 11.5, .weight = .semibold, .color = pal.ink });
            ui.end(c);
            if (mode_btn.clicked) {
                self.mode = switch (self.mode) {
                    .paper => .dark,
                    .dark => .light,
                    .light => .paper,
                };
                c.changed = true;
            }

            ui.key(c, "btn-pin-shelf");
            const pin_btn = ui.pressable(c, .{
                .padding = .{ .left = 8, .right = 8, .top = 3, .bottom = 3 },
                .radius = 999,
            }, pal.code_bg);
            ui.text(c, "+ Shelf", .{ .size = 11.5, .weight = .medium, .color = pal.accent });
            ui.end(c);
            if (pin_btn.clicked and self.shelf.entries.items.len > 0) {
                const active = self.shelf.entries.items[@min(self.selected, self.shelf.entries.items.len - 1)];
                _ = self.shelf.saveArtifact(active.name, active.raw) catch {};
                self.shelf.reload(self.explicit_file);
                self.status_toast = "Saved to .nanoui/shelf/";
                c.changed = true;
            }

            ui.key(c, "btn-mcp");
            const mcp_btn = ui.pressable(c, .{
                .padding = .{ .left = 8, .right = 8, .top = 3, .bottom = 3 },
                .radius = 999,
                .background = if (self.show_mcp_panel) pal.code_bg else .transparent,
            }, pal.code_bg);
            const is_mcp_up = self.mcp_listening.load(.monotonic);
            ui.row(c, .{ .align_items = .center, .gap = 5 });
            ui.row(c, .{
                .width = .{ .px = 7 },
                .height = .{ .px = 7 },
                .radius = 999,
                .background = if (is_mcp_up) .hex(0x22c55e) else pal.accent,
            });
            ui.end(c);
            ui.text(c, c.print("MCP · :{d}", .{self.shelf.env.mcp_port}), .{ .size = 11.5, .weight = .medium, .color = pal.ink });
            ui.end(c);
            ui.end(c);
            if (mcp_btn.clicked) {
                self.show_mcp_panel = !self.show_mcp_panel;
                c.changed = true;
            }

            ui.key(c, "btn-env");
            const env_btn = ui.pressable(c, .{
                .padding = .{ .left = 8, .right = 8, .top = 3, .bottom = 3 },
                .radius = 999,
                .background = if (self.show_env_panel) pal.code_bg else .transparent,
            }, pal.code_bg);
            const has_discord = self.shelf.env.guild_id.len > 0;
            ui.row(c, .{ .align_items = .center, .gap = 5 });
            ui.row(c, .{
                .width = .{ .px = 7 },
                .height = .{ .px = 7 },
                .radius = 999,
                .background = if (has_discord) .hex(0x22c55e) else pal.muted,
            });
            ui.end(c);
            ui.text(c, "Discord · .env", .{ .size = 11.5, .weight = .medium, .color = pal.ink });
            ui.end(c);
            ui.end(c);
            if (env_btn.clicked) {
                self.show_env_panel = !self.show_env_panel;
                c.changed = true;
            }
        }
    }

    fn renderEnvPanel(self: *AppState, c: *ui.Context, pal: render.Palette) void {
        ui.row(c, .{
            .width = .fill,
            .padding = .{ .left = 20, .right = 20, .top = 10, .bottom = 10 },
            .background = pal.card,
            .border = pal.border,
            .border_width = 1,
            .align_items = .center,
            .gap = 14,
        });
        defer ui.end(c);

        const env = self.shelf.env;
        ui.text(c, c.print("Guild: {s}", .{if (env.guild_id.len > 0) env.guild_id else "not set"}), .{
            .size = 12,
            .mono = true,
            .color = pal.ink,
        });
        ui.text(c, c.print("Invite: {s}", .{env.invite_url}), .{
            .size = 12,
            .color = pal.muted,
        });
        ui.spacer(c);

        ui.key(c, "copy-invite");
        const cp_inv = ui.pressable(c, .{
            .padding = .{ .left = 10, .right = 10, .top = 4, .bottom = 4 },
            .radius = 6,
            .background = pal.code_bg,
        }, pal.border);
        ui.text(c, "Copy Invite", .{ .size = 11.5, .weight = .semibold, .color = pal.ink });
        ui.end(c);
        if (cp_inv.clicked) {
            c.clipboard.write(c.clipboard.ctx, env.invite_url);
        }

        if (env.webhook_url.len > 0) {
            ui.key(c, "copy-webhook");
            const cp_wh = ui.pressable(c, .{
                .padding = .{ .left = 10, .right = 10, .top = 4, .bottom = 4 },
                .radius = 6,
                .background = pal.accent,
            }, pal.accent);
            ui.text(c, "Copy GitHub Webhook", .{ .size = 11.5, .weight = .semibold, .color = .hex(0xffffff) });
            ui.end(c);
            if (cp_wh.clicked) {
                const gh_wh = c.print("{s}/github", .{env.webhook_url});
                c.clipboard.write(c.clipboard.ctx, gh_wh);
            }
        }
    }

    fn renderMcpPanel(self: *AppState, c: *ui.Context, pal: render.Palette) void {
        ui.row(c, .{
            .width = .fill,
            .padding = .{ .left = 20, .right = 20, .top = 10, .bottom = 10 },
            .background = pal.card,
            .border = pal.border,
            .border_width = 1,
            .align_items = .center,
            .gap = 12,
        });
        defer ui.end(c);

        const port = self.shelf.env.mcp_port;
        const calls = self.mcp_calls.load(.monotonic);
        ui.text(c, c.print("Streamable HTTP MCP: http://127.0.0.1:{d}/mcp ({d} calls)", .{ port, calls }), .{
            .size = 12,
            .mono = true,
            .color = pal.ink,
        });
        ui.spacer(c);

        ui.key(c, "copy-mcp-http");
        const cp_http = ui.pressable(c, .{
            .padding = .{ .left = 10, .right = 10, .top = 4, .bottom = 4 },
            .radius = 6,
            .background = pal.accent,
        }, pal.accent);
        ui.text(c, "Copy HTTP MCP JSON", .{ .size = 11.5, .weight = .semibold, .color = .hex(0xffffff) });
        ui.end(c);
        if (cp_http.clicked) {
            const json = c.print("{{\"mcpServers\":{{\"nanodocs\":{{\"type\":\"http\",\"url\":\"http://127.0.0.1:{d}/mcp\"}}}}}}", .{port});
            c.clipboard.write(c.clipboard.ctx, json);
        }

        ui.key(c, "copy-mcp-claude");
        const cp_claude = ui.pressable(c, .{
            .padding = .{ .left = 10, .right = 10, .top = 4, .bottom = 4 },
            .radius = 6,
            .background = pal.code_bg,
        }, pal.border);
        ui.text(c, "Copy claude mcp add", .{ .size = 11.5, .weight = .semibold, .color = pal.ink });
        ui.end(c);
        if (cp_claude.clicked) {
            const cmd = c.print("claude mcp add --transport http nanodocs http://127.0.0.1:{d}/mcp", .{port});
            c.clipboard.write(c.clipboard.ctx, cmd);
        }
    }

    pub fn notifyFromMcp(ctx: ?*anyopaque, _: []const u8) void {
        const self: *AppState = @ptrCast(@alignCast(ctx orelse return));
        _ = self.mcp_calls.fetchAdd(1, .monotonic);
        self.mcp_dirty.store(true, .release);
        if (comptime builtin.os.tag == .macos) {
            nanoui.objc.dispatchMain(self, redrawOnMain);
        }
    }

    fn redrawOnMain(ctx: ?*anyopaque) callconv(.c) void {
        const self: *AppState = @ptrCast(@alignCast(ctx orelse return));
        if (self.window) |w| w.redraw();
    }
};
