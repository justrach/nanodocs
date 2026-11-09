//! Intertwines `nanodocs` with the local Harness engine (`ws://127.0.0.1:27664`)
//! and local agent CLIs — working 100% in Local Mode (even when the user has
//! never logged into a Harness cloud account) as well as Synced Mode.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const json = std.json;
const Io = std.Io;
const hws = @import("harness_ws.zig");
const WsClient = hws.WsClient;

pub const default_port: u16 = 27664;

pub const TargetKind = enum { chat, new_agent };

pub const Target = struct {
    kind: TargetKind,
    id: []const u8,
    label: []const u8,
    harness: []const u8,
    cwd: []const u8,
    busy: bool = false,
};

pub const Bridge = struct {
    gpa: std.mem.Allocator,
    io: Io,
    port: u16 = default_port,
    arena: std.heap.ArenaAllocator,
    connected: bool = false,
    auth_mode: []const u8 = "local (no login)",
    device_id: ?[]const u8 = null,
    mcp_wired: bool = false,
    targets: std.ArrayList(Target) = .empty,
    selected_idx: usize = 0,
    last_route: [160]u8 = undefined,
    last_route_len: usize = 0,
    probed_once: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: Io) Bridge {
        return .{
            .gpa = gpa,
            .io = io,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *Bridge) void {
        self.targets.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn lastRouteText(self: *const Bridge) []const u8 {
        return self.last_route[0..self.last_route_len];
    }

    fn setLastRoute(self: *Bridge, msg: []const u8) void {
        const n = @min(msg.len, self.last_route.len);
        @memcpy(self.last_route[0..n], msg[0..n]);
        self.last_route_len = n;
    }

    pub fn activeTarget(self: *const Bridge) ?Target {
        if (self.targets.items.len == 0) return null;
        return self.targets.items[@min(self.selected_idx, self.targets.items.len - 1)];
    }

    pub fn cycleTarget(self: *Bridge) void {
        if (self.targets.items.len == 0) return;
        self.selected_idx = (self.selected_idx + 1) % self.targets.items.len;
    }

    /// Probes `ws://127.0.0.1:27664` for EngineInfo, ListHarnesses, WatchChats & WatchSessions,
    /// and populates selectable targets (active chats + local agents).
    pub fn refresh(self: *Bridge, root_dir: []const u8) void {
        self.probed_once = true;
        _ = self.arena.reset(.retain_capacity);
        self.targets.clearRetainingCapacity();
        const a = self.arena.allocator();

        self.mcp_wired = hws.hasNanodocsInMcpJson(self.gpa, self.io, root_dir);

        var cwd_buf: [512]u8 = undefined;
        const cwd_str = hws.resolveCwd(self.io, root_dir, &cwd_buf);
        const cwd_duped = a.dupe(u8, cwd_str) catch ".";

        var client = WsClient.connect(self.io, self.port) catch {
            self.connected = false;
            self.auth_mode = "offline (local CLIs ready)";
            self.populateFallbackAgents(a, cwd_duped);
            return;
        };
        defer client.close();
        self.connected = true;

        client.sendText(
            \\{"id":1,"method":"EngineInfo","params":{}}
            \\{"id":2,"method":"ListHarnesses","params":{}}
            \\{"id":3,"method":"WatchSessions","params":{}}
            \\{"id":4,"method":"WatchChats","params":{}}
        ) catch {};

        var sessions_busy: std.StringHashMapUnmanaged(bool) = .empty;
        var chats_json: ?json.Parsed(json.Value) = null;
        defer if (chats_json) |*cj| cj.deinit();
        var harnesses_json: ?json.Parsed(json.Value) = null;
        defer if (harnesses_json) |*hj| hj.deinit();

        var frame_buf: std.ArrayList(u8) = .empty;
        defer frame_buf.deinit(self.gpa);

        var frames_read: usize = 0;
        while (frames_read < 6) : (frames_read += 1) {
            client.readText(self.gpa, &frame_buf) catch break;
            const parsed = json.parseFromSlice(json.Value, self.gpa, frame_buf.items, .{}) catch continue;
            var keep_parsed = false;
            defer if (!keep_parsed) parsed.deinit();
            if (parsed.value != .object) continue;
            const obj = parsed.value.object;
            const id_val = obj.get("id") orelse continue;
            const id = if (id_val == .integer) id_val.integer else continue;

            if (id == 1) {
                if (obj.get("ok")) |ok| if (ok == .object) {
                    if (ok.object.get("deviceId")) |d| if (d == .string) {
                        self.device_id = a.dupe(u8, d.string) catch null;
                    };
                    if (ok.object.get("workspaceScope")) |sc| if (sc == .string) {
                        self.auth_mode = if (std.mem.eql(u8, sc.string, "local"))
                            "local (no login)"
                        else
                            (a.dupe(u8, sc.string) catch "synced");
                    };
                };
            } else if (id == 2) {
                if (obj.get("ok")) |ok| if (ok == .array) {
                    if (harnesses_json) |*old| old.deinit();
                    harnesses_json = parsed;
                    keep_parsed = true;
                };
            } else if (id == 3) {
                if (obj.get("item")) |it| if (it == .array) {
                    for (it.array.items) |s| if (s == .object) {
                        const cid = if (s.object.get("chatId")) |v| (if (v == .string) v.string else null) else null;
                        const st = if (s.object.get("status")) |v| (if (v == .string) v.string else "") else "";
                        if (cid) |c_id| {
                            const busy = std.mem.eql(u8, st, "working") or std.mem.eql(u8, st, "awaitingInput");
                            if (busy) sessions_busy.put(a, a.dupe(u8, c_id) catch continue, true) catch {};
                        }
                    };
                };
            } else if (id == 4) {
                if (obj.get("item")) |it| if (it == .array) {
                    if (chats_json) |*old| old.deinit();
                    chats_json = parsed;
                    keep_parsed = true;
                };
            }
            if (chats_json != null and harnesses_json != null and self.device_id != null) break;
        }

        const ScoredChat = struct {
            stamp: []const u8,
            target: Target,
        };
        var scored: std.ArrayList(ScoredChat) = .empty;

        if (chats_json) |cj| {
            const arr = cj.value.object.get("item").?.array.items;
            for (arr) |v| {
                if (v != .object) continue;
                const o = v.object;
                if (o.get("archived")) |ar| if (ar == .bool and ar.bool) continue;
                if (o.get("parentChatId")) |p| if (p == .string and p.string.len > 0) continue;
                const cid = if (o.get("id")) |x| (if (x == .string) x.string else null) else null;
                if (cid == null) continue;
                const title_raw = if (o.get("title")) |x| (if (x == .string and x.string.len > 0) x.string else null) else null;
                const cfg = if (o.get("config")) |x| (if (x == .object) x.object else null) else null;
                const h_id = if (cfg) |c_obj| (if (c_obj.get("harness")) |h| (if (h == .string) h.string else "graff") else "graff") else "graff";
                const chat_cwd = if (o.get("cwd")) |x| (if (x == .string and x.string.len > 0) x.string else cwd_duped) else cwd_duped;
                const stamp = if (o.get("lastPromptAt")) |x| (if (x == .string and x.string.len > 0) x.string else "") else if (o.get("lastMessageAt")) |x| (if (x == .string and x.string.len > 0) x.string else "") else if (o.get("createdAt")) |x| (if (x == .string) x.string else "") else "";
                const title = title_raw orelse "Untitled chat";
                const short_title = if (title.len > 22) title[0..22] else title;
                const busy = sessions_busy.get(cid.?) orelse false;
                const label = std.fmt.allocPrint(a, "Chat: {s} ({s})", .{ short_title, h_id }) catch continue;
                scored.append(a, .{
                    .stamp = a.dupe(u8, stamp) catch "",
                    .target = .{
                        .kind = .chat,
                        .id = a.dupe(u8, cid.?) catch continue,
                        .label = label,
                        .harness = a.dupe(u8, h_id) catch "graff",
                        .cwd = a.dupe(u8, chat_cwd) catch cwd_duped,
                        .busy = busy,
                    },
                }) catch {};
            }
        }

        std.mem.sort(ScoredChat, scored.items, {}, struct {
            fn lt(_: void, lhs: ScoredChat, rhs: ScoredChat) bool {
                return std.mem.order(u8, lhs.stamp, rhs.stamp) == .gt;
            }
        }.lt);

        for (scored.items[0..@min(scored.items.len, 5)]) |sc| {
            self.targets.append(self.gpa, sc.target) catch {};
        }

        if (harnesses_json) |hj| {
            for (hj.value.object.get("ok").?.array.items) |v| {
                if (v != .object) continue;
                const o = v.object;
                const id = if (o.get("id")) |x| (if (x == .string) x.string else null) else null;
                if (id == null or std.mem.eql(u8, id.?, "mock")) continue;
                const inst = if (o.get("installed")) |x| (x == .bool and x.bool) else false;
                if (!inst) continue;
                const label = std.fmt.allocPrint(a, "+ New {s} chat", .{id.?}) catch continue;
                self.targets.append(self.gpa, .{
                    .kind = .new_agent,
                    .id = a.dupe(u8, id.?) catch continue,
                    .label = label,
                    .harness = a.dupe(u8, id.?) catch continue,
                    .cwd = cwd_duped,
                }) catch {};
            }
        }
        if (self.targets.items.len == 0) {
            self.populateFallbackAgents(a, cwd_duped);
        }
        if (self.selected_idx >= self.targets.items.len) self.selected_idx = 0;
    }

    fn populateFallbackAgents(self: *Bridge, a: std.mem.Allocator, cwd_duped: []const u8) void {
        const defaults = [_][]const u8{ "graff", "claude-code", "codex", "cursor", "antigravity" };
        for (defaults) |ag| {
            const label = std.fmt.allocPrint(a, "+ New {s} chat", .{ag}) catch continue;
            self.targets.append(self.gpa, .{
                .kind = .new_agent,
                .id = ag,
                .label = label,
                .harness = ag,
                .cwd = cwd_duped,
            }) catch {};
        }
    }

    /// 1-Click Connect: wires `.mcp.json`, starts `harness headless` if needed, reconnects MCP.
    pub fn connectAll(self: *Bridge, root_dir: []const u8, mcp_port: u16) void {
        hws.wireMcpJson(self.gpa, self.io, root_dir, mcp_port);
        self.mcp_wired = true;

        if (!hws.isPortListening(self.io, self.port)) {
            hws.startHeadlessEngine(self.gpa, self.io);
            var tries: usize = 0;
            while (tries < 15) : (tries += 1) {
                if (hws.isPortListening(self.io, self.port)) break;
                self.io.sleep(.fromMilliseconds(80), .awake) catch {};
            }
        }

        if (WsClient.connect(self.io, self.port)) |*client| {
            var c = client.*;
            defer c.close();
            c.sendText("{\"id\":99,\"method\":\"McpServerAction\",\"params\":{\"action\":\"reconnect\",\"name\":\"nanodocs\"}}") catch {};
            var resp: std.ArrayList(u8) = .empty;
            defer resp.deinit(self.gpa);
            c.readText(self.gpa, &resp) catch {};
        } else |_| {}

        self.refresh(root_dir);
        if (self.connected) {
            self.setLastRoute("Connected to Harness (local · no login needed) + wired .mcp.json");
        } else {
            self.setLastRoute("Wired .mcp.json for Harness / Claude / Cursor / Graff");
        }
    }

    /// Sends feedback from `nanodocs` directly into the active Harness chat (or spawns a new
    /// local agent chat in Harness if a `+ New <agent> chat` target is selected).
    pub fn sendFeedback(
        self: *Bridge,
        root_dir: []const u8,
        doc_name: []const u8,
        status: []const u8,
        message: []const u8,
        edited: bool,
    ) bool {
        if (!self.probed_once) self.refresh(root_dir);
        if (!self.connected) {
            if (hws.isPortListening(self.io, self.port)) self.refresh(root_dir);
        }
        const target = self.activeTarget() orelse return false;

        var client = WsClient.connect(self.io, self.port) catch return false;
        defer client.close();

        const edit_note = if (edited) " (includes live saved edits in file)" else "";
        const prompt = std.fmt.allocPrint(
            self.gpa,
            "[nanodocs {s} on `.nanoui/shelf/{s}`{s}]: {s}",
            .{ status, doc_name, edit_note, message },
        ) catch return false;
        defer self.gpa.free(prompt);

        var esc_prompt: Io.Writer.Allocating = .init(self.gpa);
        defer esc_prompt.deinit();
        hws.writeJsonStr(&esc_prompt.writer, prompt) catch return false;

        var msg_uuid: [36]u8 = undefined;
        hws.makeUuid(self.io, &msg_uuid);

        if (target.kind == .chat) {
            if (target.busy) {
                const payload = std.fmt.allocPrint(
                    self.gpa,
                    "{{\"id\":10,\"method\":\"QueueMessage\",\"params\":{{\"chatId\":\"{s}\",\"text\":{s},\"holdForTurnEnd\":true}}}}",
                    .{ target.id, esc_prompt.written() },
                ) catch return false;
                defer self.gpa.free(payload);
                client.sendText(payload) catch return false;
            } else {
                const payload = std.fmt.allocPrint(
                    self.gpa,
                    "{{\"id\":10,\"method\":\"QueueCommand\",\"params\":{{\"chatId\":\"{s}\",\"command\":{{\"kind\":\"run\",\"messageId\":\"{s}\",\"request\":{{\"prompt\":{s},\"turnOrigin\":\"human\",\"harness\":\"{s}\",\"cwd\":\"{s}\",\"sandbox\":\"workspace-write\",\"autoApprove\":false}}}}}}}}",
                    .{ target.id, &msg_uuid, esc_prompt.written(), target.harness, target.cwd },
                ) catch return false;
                defer self.gpa.free(payload);
                client.sendText(payload) catch return false;
            }
            var reply_buf: std.ArrayList(u8) = .empty;
            defer reply_buf.deinit(self.gpa);
            client.readText(self.gpa, &reply_buf) catch {};

            var note_buf: [160]u8 = undefined;
            const note = std.fmt.bufPrint(&note_buf, "Sent → Harness {s}", .{target.label}) catch "Sent → Harness";
            self.setLastRoute(note);
            return true;
        } else {
            var chat_uuid: [36]u8 = undefined;
            hws.makeUuid(self.io, &chat_uuid);
            const dev_field = if (self.device_id) |d|
                (std.fmt.allocPrint(self.gpa, ",\"deviceId\":\"{s}\"", .{d}) catch "")
            else
                (self.gpa.dupe(u8, "") catch "");
            defer self.gpa.free(dev_field);

            const payload = std.fmt.allocPrint(
                self.gpa,
                "{{\"id\":11,\"method\":\"Mutate\",\"params\":{{\"op\":\"createChat\",\"chatId\":\"{s}\",\"spaceId\":null{s},\"config\":{{\"harness\":\"{s}\",\"sandbox\":\"workspace-write\"}}}}}}\n" ++
                    "{{\"id\":12,\"method\":\"QueueCommand\",\"params\":{{\"chatId\":\"{s}\",\"command\":{{\"kind\":\"run\",\"messageId\":\"{s}\",\"request\":{{\"prompt\":{s},\"turnOrigin\":\"human\",\"harness\":\"{s}\",\"cwd\":\"{s}\",\"sandbox\":\"workspace-write\",\"autoApprove\":false}}}}}}}}",
                .{ &chat_uuid, dev_field, target.harness, &chat_uuid, &msg_uuid, esc_prompt.written(), target.harness, target.cwd },
            ) catch return false;
            defer self.gpa.free(payload);
            client.sendText(payload) catch return false;

            var reply_buf: std.ArrayList(u8) = .empty;
            defer reply_buf.deinit(self.gpa);
            client.readText(self.gpa, &reply_buf) catch {};

            var note_buf: [160]u8 = undefined;
            const note = std.fmt.bufPrint(&note_buf, "Started new Harness chat ({s})", .{target.harness}) catch "Started Harness chat";
            self.setLastRoute(note);
            self.refresh(root_dir);
            return true;
        }
    }

    pub fn ensureProbed(self: *Bridge, root_dir: []const u8) void {
        if (!self.probed_once) self.refresh(root_dir);
    }

    /// Renders the interactive Harness Bridge pills inside the bottom Agent Bridge bar.
    pub fn renderBridgePills(self: *Bridge, c: *ui.Context, is_dark: bool, root_dir: []const u8, mcp_port: u16) void {
        if (self.targets.items.len == 0) {
            self.populateFallbackAgents(self.arena.allocator(), ".");
        }

        const text_muted = if (is_dark) ui.Color.hex(0x94a3b8) else ui.Color.hex(0x475569);
        const pill_bg = if (is_dark) ui.Color.hex(0x1e293b) else ui.Color.hex(0xe2e8f0);
        const conn_bg = if (self.connected)
            (if (is_dark) ui.Color.hex(0x064e3b) else ui.Color.hex(0xd1fae5))
        else
            (if (is_dark) ui.Color.hex(0x3b2f63) else ui.Color.hex(0xede9fe));
        const conn_fg = if (self.connected)
            (if (is_dark) ui.Color.hex(0x6ee7b7) else ui.Color.hex(0x047857))
        else
            (if (is_dark) ui.Color.hex(0xc4b5fd) else ui.Color.hex(0x6d28d9));

        // 1. Harness Connection / 1-Click Connect Pill
        {
            ui.key(c, "harness-conn-pill");
            const b = ui.div(c).row().itemsCenter().px(8).py(3).rounded(5).bg(conn_bg);
            defer b.end();
            const label = if (self.connected)
                c.print("🔗 Harness: {s}", .{self.auth_mode})
            else
                "🔗 Connect Harness (No Login)";
            ui.text(c, label, .{ .size = 10.5, .weight = .bold, .color = conn_fg });
            if (b.clicked()) {
                self.connectAll(root_dir, mcp_port);
                c.changed = true;
            }
        }

        // 2. Target Selector Pill (cycles through active Harness chats & local agents)
        if (self.activeTarget()) |t| {
            ui.key(c, "harness-target-pill");
            const tb = ui.div(c).row().itemsCenter().px(8).py(3).rounded(5).bg(pill_bg);
            defer tb.end();
            ui.text(c, c.print("🎯 → {s} ▾", .{t.label}), .{ .size = 10.5, .weight = .medium, .color = text_muted });
            if (tb.clicked()) {
                self.cycleTarget();
                c.changed = true;
            }
        }

        // 3. `.mcp.json` wire-up pill if not yet wired
        if (!self.mcp_wired) {
            ui.key(c, "harness-wire-mcp");
            const wb = ui.div(c).row().itemsCenter().px(8).py(3).rounded(5).bg(pill_bg);
            defer wb.end();
            ui.text(c, "⚡ Wire .mcp.json", .{ .size = 10.5, .weight = .semibold, .color = conn_fg });
            if (wb.clicked()) {
                self.connectAll(root_dir, mcp_port);
                c.changed = true;
            }
        }
    }
};
