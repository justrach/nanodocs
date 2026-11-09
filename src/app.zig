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
const editor_mod = @import("editor.zig");

pub const AppState = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    shelf: shelf_mod.Shelf,
    editor: editor_mod.EditorState,
    images: render.ImageCache = .{},
    selected: usize = 0,
    mode: render.CanvasMode = .paper,
    view_mode: editor_mod.ViewMode = .rendered,
    show_sidebar: bool = true,
    show_env_panel: bool = false,
    show_mcp_panel: bool = false,
    was_resizing: bool = false,
    status_toast: []const u8 = "",
    explicit_file: ?[]const u8 = null,
    window: ?*nanoui.Window = null,
    mcp_listening: std.atomic.Value(bool) = .init(false),
    mcp_dirty: std.atomic.Value(bool) = .init(false),
    mcp_want_split: std.atomic.Value(bool) = .init(false),
    mcp_calls: std.atomic.Value(u64) = .init(0),
    last_mcp_name_buf: [128]u8 = undefined,
    last_mcp_name_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, explicit_file: ?[]const u8) AppState {
        var s: AppState = .{
            .gpa = gpa,
            .io = io,
            .shelf = .init(gpa, io),
            .editor = .init(gpa, io),
            .explicit_file = explicit_file,
        };
        s.shelf.reload(explicit_file);
        return s;
    }

    pub fn deinit(self: *AppState) void {
        self.editor.deinit();
        self.images.deinit(self.gpa);
        self.shelf.deinit();
    }

    pub fn view(self: *AppState, c: *ui.Context) void {
        if (self.was_resizing and !c.live_resizing) {
            c.changed = true;
        }
        self.was_resizing = c.live_resizing;

        if (!c.live_resizing and self.mcp_dirty.swap(false, .acquire)) {
            self.shelf.reload(self.explicit_file);
            const target = self.last_mcp_name_buf[0..self.last_mcp_name_len];
            self.selected = 0;
            if (target.len > 0) {
                for (self.shelf.entries.items, 0..) |ent, i| {
                    if (std.mem.eql(u8, ent.name, target)) {
                        self.selected = i;
                        self.editor.forceReload(i, ent);
                        break;
                    }
                }
                self.status_toast = "⚡ Live from Agent MCP";
            }
            if (self.mcp_want_split.swap(false, .acquire)) {
                self.view_mode = .split;
            }
            c.changed = true;
        }

        if (c.shortcut(.{ .key = 't', .cmd = true })) {
            self.mode = switch (self.mode) {
                .paper => .dark,
                .dark => .light,
                .light => .paper,
            };
        }
        if (c.shortcut(.{ .key = 'b', .cmd = true })) self.show_sidebar = !self.show_sidebar;
        if (c.shortcut(.{ .key = 'e', .cmd = true })) self.view_mode = self.view_mode.next();
        if (c.shortcut(.{ .key = 'd', .cmd = true })) self.show_env_panel = !self.show_env_panel;
        if (c.shortcut(.{ .key = 'm', .cmd = true })) self.show_mcp_panel = !self.show_mcp_panel;
        if (c.shortcut(.{ .key = 's', .cmd = true })) {
            if (self.editor.saveCurrent(&self.shelf, self.selected)) |_| {
                self.status_toast = "✓ Saved edits";
            }
        }
        if (c.shortcut(.{ .key = 'r', .cmd = true }) and !c.live_resizing) {
            self.shelf.reload(self.explicit_file);
            if (self.shelf.entries.items.len > 0) {
                const idx = @min(self.selected, self.shelf.entries.items.len - 1);
                self.editor.forceReload(idx, self.shelf.entries.items[idx]);
            }
        }
        inline for (0..9) |i| {
            if (c.shortcut(.{ .key = '1' + i, .cmd = true })) {
                if (i < self.shelf.entries.items.len) self.selected = i;
            }
        }

        const pal = render.Palette.forMode(self.mode);
        const sidebar_w: f32 = if (!self.show_sidebar) 0 else if (c.size.w < 860) 196 else 248;
        const pane_w: f32 = @max(c.size.w - sidebar_w, 240);

        ui.row(c, .{
            .width = .fill,
            .height = .fill,
            .background = pal.bg,
        });
        defer ui.end(c);

        if (self.show_sidebar) {
            self.renderSidebar(c, pal, sidebar_w);
        }

        ui.column(c, .{
            .width = .{ .px = pane_w },
            .height = .fill,
            .background = pal.bg,
        });
        defer ui.end(c);

        self.renderTopGlassBar(c, pal, pane_w);
        ui.row(c, .{ .width = .fill, .height = .{ .px = 1 }, .background = pal.border });
        ui.end(c);

        if (self.show_mcp_panel) {
            self.renderMcpPanel(c, pal, pane_w);
        }
        if (self.show_env_panel) {
            self.renderEnvPanel(c, pal, pane_w);
        }

        if (self.shelf.entries.items.len == 0) {
            ui.column(c, .{ .width = .fill, .grow = 1, .align_items = .center, .justify = .center });
            ui.text(c, "No Markdown or HTML documents found.", .{ .size = 15, .color = pal.muted });
            ui.end(c);
            return;
        }

        const idx = @min(self.selected, self.shelf.entries.items.len - 1);
        const active = self.shelf.entries.items[idx];
        self.editor.syncDocument(idx, active);
        const live_doc = self.editor.activeDoc(active.doc);
        const live_raw = self.editor.activeRaw(active.raw);

        switch (self.view_mode) {
            .rendered => {
                const content_width: f32 = @min(@max(pane_w - 48, 200), 700);
                ui.scroll(c, .{ .width = .fill, .grow = 1 });
                render.renderDocument(
                    c,
                    live_doc,
                    live_raw,
                    false,
                    pal,
                    &self.images,
                    self.gpa,
                    self.io,
                    self.shelf.root_dir,
                    c.live_resizing,
                    content_width,
                );
                ui.end(c);
            },
            .source => {
                self.editor.renderEditorPane(c, pal, &self.shelf, idx, pane_w, &self.status_toast);
            },
            .split => {
                const ed_w = @floor(pane_w * 0.45);
                const prev_w = @max(pane_w - ed_w, 200);
                const content_width: f32 = @min(@max(prev_w - 36, 180), 680);
                ui.row(c, .{ .width = .fill, .grow = 1 });
                self.editor.renderEditorPane(c, pal, &self.shelf, idx, ed_w, &self.status_toast);
                ui.column(c, .{ .width = .{ .px = prev_w }, .height = .fill });
                ui.scroll(c, .{ .width = .fill, .grow = 1 });
                render.renderDocument(
                    c,
                    live_doc,
                    live_raw,
                    false,
                    pal,
                    &self.images,
                    self.gpa,
                    self.io,
                    self.shelf.root_dir,
                    c.live_resizing,
                    content_width,
                );
                ui.end(c);
                ui.end(c);
                ui.end(c);
            },
        }

        self.editor.renderAgentCommsBar(c, pal, &self.shelf, idx, pane_w, &self.status_toast);
    }

    fn renderSidebar(self: *AppState, c: *ui.Context, pal: render.Palette, sidebar_w: f32) void {
        ui.column(c, .{
            .width = .{ .px = sidebar_w },
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

    fn renderTopGlassBar(self: *AppState, c: *ui.Context, pal: render.Palette, pane_w: f32) void {
        const compact = pane_w < 820;
        const pad_x: f32 = if (compact) 12 else 20;
        ui.row(c, .{
            .width = .fill,
            .padding = .{ .top = 12, .bottom = 10, .left = pad_x, .right = pad_x },
            .align_items = .center,
            .gap = 8,
            .background = pal.bg,
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

            if (self.shelf.entries.items.len > 0 and (pane_w >= 560 or !self.show_sidebar)) {
                const active = self.shelf.entries.items[@min(self.selected, self.shelf.entries.items.len - 1)];
                const max_name: usize = if (pane_w < 640) 14 else if (compact) 22 else 44;
                const display_name = if (active.name.len > max_name)
                    c.print("{s}…", .{active.name[0..max_name]})
                else
                    active.name;
                ui.text(c, display_name, .{ .size = 12, .weight = .semibold, .color = pal.ink });
                if (!compact and self.status_toast.len == 0) {
                    ui.text(c, "·", .{ .size = 12, .color = pal.muted });
                    ui.text(c, c.print("{d} words", .{active.doc.word_count}), .{ .size = 11.5, .color = pal.muted });
                }
            }
            if (self.status_toast.len > 0) {
                ui.row(c, .{
                    .padding = .{ .left = 7, .right = 7, .top = 2, .bottom = 2 },
                    .radius = 999,
                    .background = pal.accent,
                });
                const toast_lbl = if (pane_w < 920) "⚡ MCP" else self.status_toast;
                ui.text(c, toast_lbl, .{ .size = 10.5, .weight = .bold, .color = .hex(0xffffff) });
                ui.end(c);
            }
            if (c.live_resizing) {
                ui.row(c, .{
                    .padding = .{ .left = 6, .right = 6, .top = 1, .bottom = 1 },
                    .radius = 999,
                    .background = pal.accent,
                });
                ui.text(c, "120Hz", .{ .size = 10, .weight = .bold, .color = .hex(0xffffff) });
                ui.end(c);
            }
        }

        ui.spacer(c);

        // Right Liquid Glass capsule: Rendered/Split/Source, Paper/Light/Dark, Pin to Shelf, MCP, Discord .env
        {
            const right = render.glassPill(c, pal);
            defer right.end();
            const btn_pad: f32 = if (compact) 6 else 8;
            ui.key(c, "btn-raw");
            const raw_btn = ui.pressable(c, .{
                .padding = .{ .left = btn_pad, .right = btn_pad, .top = 3, .bottom = 3 },
                .radius = 999,
                .background = if (self.view_mode != .rendered) pal.code_bg else .transparent,
            }, pal.code_bg);
            ui.text(c, self.view_mode.label(), .{ .size = 11.5, .weight = .medium, .color = pal.ink });
            ui.end(c);
            if (raw_btn.clicked) {
                self.view_mode = self.view_mode.next();
                c.changed = true;
            }

            const mode_label = switch (self.mode) {
                .paper => "Paper",
                .light => "Light",
                .dark => "Dark",
            };
            ui.key(c, "btn-mode");
            const mode_btn = ui.pressable(c, .{
                .padding = .{ .left = btn_pad, .right = btn_pad, .top = 3, .bottom = 3 },
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

            if (pane_w >= 540) {
                ui.key(c, "btn-pin-shelf");
                const pin_btn = ui.pressable(c, .{
                    .padding = .{ .left = btn_pad, .right = btn_pad, .top = 3, .bottom = 3 },
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
            }

            ui.key(c, "btn-mcp");
            const mcp_btn = ui.pressable(c, .{
                .padding = .{ .left = btn_pad, .right = btn_pad, .top = 3, .bottom = 3 },
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
            const mcp_lbl = if (compact) "MCP" else c.print("MCP · :{d}", .{self.shelf.env.mcp_port});
            ui.text(c, mcp_lbl, .{ .size = 11.5, .weight = .medium, .color = pal.ink });
            ui.end(c);
            ui.end(c);
            if (mcp_btn.clicked) {
                self.show_mcp_panel = !self.show_mcp_panel;
                c.changed = true;
            }

            ui.key(c, "btn-env");
            const env_btn = ui.pressable(c, .{
                .padding = .{ .left = btn_pad, .right = btn_pad, .top = 3, .bottom = 3 },
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
            ui.text(c, if (compact) ".env" else "Discord · .env", .{ .size = 11.5, .weight = .medium, .color = pal.ink });
            ui.end(c);
            ui.end(c);
            if (env_btn.clicked) {
                self.show_env_panel = !self.show_env_panel;
                c.changed = true;
            }
        }
    }

    fn renderEnvPanel(self: *AppState, c: *ui.Context, pal: render.Palette, pane_w: f32) void {
        ui.row(c, .{
            .width = .fill,
            .padding = .{ .left = 16, .right = 16, .top = 8, .bottom = 8 },
            .background = pal.card,
            .border = pal.border,
            .border_width = 1,
            .align_items = .center,
            .gap = 10,
        });
        defer ui.end(c);

        const env = self.shelf.env;
        ui.text(c, c.print("Guild: {s}", .{if (env.guild_id.len > 0) env.guild_id else "not set"}), .{
            .size = 11.5,
            .mono = true,
            .color = pal.ink,
        });
        if (pane_w >= 720) {
            ui.text(c, c.print("Invite: {s}", .{env.invite_url}), .{
                .size = 11.5,
                .color = pal.muted,
            });
        }
        ui.spacer(c);

        ui.key(c, "copy-invite");
        const cp_inv = ui.pressable(c, .{
            .padding = .{ .left = 9, .right = 9, .top = 4, .bottom = 4 },
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
                .padding = .{ .left = 9, .right = 9, .top = 4, .bottom = 4 },
                .radius = 6,
                .background = pal.accent,
            }, pal.accent);
            ui.text(c, if (pane_w < 680) "Webhook" else "Copy GitHub Webhook", .{ .size = 11.5, .weight = .semibold, .color = .hex(0xffffff) });
            ui.end(c);
            if (cp_wh.clicked) {
                const gh_wh = c.print("{s}/github", .{env.webhook_url});
                c.clipboard.write(c.clipboard.ctx, gh_wh);
            }
        }
    }

    fn renderMcpPanel(self: *AppState, c: *ui.Context, pal: render.Palette, pane_w: f32) void {
        ui.row(c, .{
            .width = .fill,
            .padding = .{ .left = 16, .right = 16, .top = 8, .bottom = 8 },
            .background = pal.card,
            .border = pal.border,
            .border_width = 1,
            .align_items = .center,
            .gap = 10,
        });
        defer ui.end(c);

        const port = self.shelf.env.mcp_port;
        const calls = self.mcp_calls.load(.monotonic);
        const label_str = if (pane_w < 720)
            c.print("http://127.0.0.1:{d}/mcp ({d})", .{ port, calls })
        else
            c.print("Streamable HTTP MCP: http://127.0.0.1:{d}/mcp ({d} calls)", .{ port, calls });
        ui.text(c, label_str, .{
            .size = 11.5,
            .mono = true,
            .color = pal.ink,
        });
        ui.spacer(c);

        ui.key(c, "copy-mcp-http");
        const cp_http = ui.pressable(c, .{
            .padding = .{ .left = 9, .right = 9, .top = 4, .bottom = 4 },
            .radius = 6,
            .background = pal.accent,
        }, pal.accent);
        ui.text(c, if (pane_w < 680) "Copy JSON" else "Copy HTTP MCP JSON", .{ .size = 11.5, .weight = .semibold, .color = .hex(0xffffff) });
        ui.end(c);
        if (cp_http.clicked) {
            const json = c.print("{{\"mcpServers\":{{\"nanodocs\":{{\"type\":\"http\",\"url\":\"http://127.0.0.1:{d}/mcp\"}}}}}}", .{port});
            c.clipboard.write(c.clipboard.ctx, json);
        }

        ui.key(c, "copy-mcp-claude");
        const cp_claude = ui.pressable(c, .{
            .padding = .{ .left = 9, .right = 9, .top = 4, .bottom = 4 },
            .radius = 6,
            .background = pal.code_bg,
        }, pal.border);
        ui.text(c, if (pane_w < 680) "claude mcp" else "Copy claude mcp add", .{ .size = 11.5, .weight = .semibold, .color = pal.ink });
        ui.end(c);
        if (cp_claude.clicked) {
            const cmd = c.print("claude mcp add --transport http nanodocs http://127.0.0.1:{d}/mcp", .{port});
            c.clipboard.write(c.clipboard.ctx, cmd);
        }
    }

    pub fn notifyFromMcp(ctx: ?*anyopaque, saved_path: []const u8) void {
        const self: *AppState = @ptrCast(@alignCast(ctx orelse return));
        const base = std.fs.path.basename(saved_path);
        const n = @min(base.len, self.last_mcp_name_buf.len);
        @memcpy(self.last_mcp_name_buf[0..n], base[0..n]);
        self.last_mcp_name_len = n;
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
