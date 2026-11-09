//! Loopback Streamable HTTP (`/mcp`) and stdio MCP transport for `nanodocs`,
//! after Codegraff's `mcp_server_http.zig`.
//!
//! Supports both stateless `2026-07-28` HTTP requests (validating
//! `MCP-Protocol-Version`, `Mcp-Method`, and `Mcp-Name`) and session-based
//! `Mcp-Session-Id` (`2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05`),
//! plus optional `Authorization: Bearer <token>`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const mcp = @import("mcp.zig");

pub const default_port: u16 = 7740;

const Session = struct {
    id: [32]u8,
    server: mcp.Server,
};

pub const HttpState = struct {
    io: Io,
    allocator: Allocator,
    token: []const u8,
    port: u16,
    prototype: mcp.Server,
    mutex: Io.Mutex = .init,
    sessions: [64]?Session = @splat(null),
    next: usize = 0,
    calls: std.atomic.Value(u64) = .init(0),
};

pub fn runHttp(io: Io, a: Allocator, port: u16, token: []const u8, prototype: mcp.Server) !void {
    const addr = try Io.net.IpAddress.parse("127.0.0.1", port);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var state: HttpState = .{
        .io = io,
        .allocator = a,
        .token = token,
        .port = port,
        .prototype = prototype,
    };
    while (true) {
        const stream = listener.accept(io) catch continue;
        handleConnection(&state, stream);
    }
}

pub fn handleConnection(st: *HttpState, stream: Io.net.Stream) void {
    defer stream.close(st.io);
    var rb: [32 * 1024]u8 = undefined;
    var wb: [8 * 1024]u8 = undefined;
    var reader = Io.net.Stream.Reader.init(stream, st.io, &rb);
    var writer = Io.net.Stream.Writer.init(stream, st.io, &wb);
    var http = std.http.Server.init(&reader.interface, &writer.interface);
    var request = http.receiveHead() catch return;
    handleRequest(st, &request) catch return;
}

fn respond(req: *std.http.Server.Request, status: std.http.Status, body: []const u8, sid: ?[]const u8) !void {
    var headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "Mcp-Session-Id", .value = sid orelse "" },
    };
    try req.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = headers[0..if (sid != null) 3 else 2],
    });
}

fn handleRequest(st: *HttpState, req: *std.http.Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(st.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    if (std.mem.eql(u8, req.head.target, "/health")) {
        const body = try std.fmt.allocPrint(a, "{{\"ok\":true,\"name\":\"nanodocs\",\"port\":{d},\"calls\":{d}}}\n", .{ st.port, st.calls.load(.monotonic) });
        return respond(req, .ok, body, null);
    }
    if (!std.mem.eql(u8, req.head.target, "/mcp")) {
        return respond(req, .not_found, "{}", null);
    }

    const host_127 = try std.fmt.allocPrint(a, "127.0.0.1:{d}", .{st.port});
    const host_local = try std.fmt.allocPrint(a, "localhost:{d}", .{st.port});
    const origin_127 = try std.fmt.allocPrint(a, "http://{s}", .{host_127});
    const origin_local = try std.fmt.allocPrint(a, "http://{s}", .{host_local});
    const bearer = if (st.token.len > 0) try std.fmt.allocPrint(a, "Bearer {s}", .{st.token}) else "";

    var authorized = st.token.len == 0;
    var host_ok = false;
    var sid: ?[]const u8 = null;
    var json_type = false;
    var protocol_header: ?[]const u8 = null;
    var method_header: ?[]const u8 = null;
    var name_header: ?[]const u8 = null;

    var headers = req.iterateHeaders();
    while (headers.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "host")) {
            host_ok = std.mem.eql(u8, h.value, host_127) or std.mem.eql(u8, h.value, host_local);
        }
        if (std.ascii.eqlIgnoreCase(h.name, "origin")) {
            if (!std.mem.eql(u8, h.value, origin_127) and !std.mem.eql(u8, h.value, origin_local)) {
                return respond(req, .forbidden, "{}", null);
            }
        }
        if (std.ascii.eqlIgnoreCase(h.name, "authorization") and st.token.len > 0) {
            authorized = equalToken(h.value, bearer);
        }
        if (std.ascii.eqlIgnoreCase(h.name, "mcp-session-id")) sid = try a.dupe(u8, h.value);
        if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
            json_type = std.mem.eql(u8, h.value, "application/json") or std.mem.startsWith(u8, h.value, "application/json;");
        }
        if (std.ascii.eqlIgnoreCase(h.name, "mcp-protocol-version")) protocol_header = try a.dupe(u8, h.value);
        if (std.ascii.eqlIgnoreCase(h.name, "mcp-method")) method_header = try a.dupe(u8, h.value);
        if (std.ascii.eqlIgnoreCase(h.name, "mcp-name")) name_header = try a.dupe(u8, h.value);
    }

    if (!host_ok) return respond(req, .forbidden, "{}", null);
    if (!authorized) return respond(req, .unauthorized, "{}", null);
    if (req.head.method != .POST and req.head.method != .DELETE) {
        return respond(req, .method_not_allowed, "{}", null);
    }

    if (protocol_header) |v| {
        const known = for (mcp.supported_versions) |s| {
            if (std.mem.eql(u8, v, s)) break true;
        } else false;
        if (!known) {
            var out: Io.Writer.Allocating = .init(a);
            try mcp.writeUnsupported(&out.writer, .null, v);
            return respond(req, .bad_request, out.written(), null);
        }
    }

    try st.mutex.lock(st.io);
    defer st.mutex.unlock(st.io);
    _ = st.calls.fetchAdd(1, .monotonic);

    var legacy_body: ?[]const u8 = null;
    if (req.head.method == .POST and json_type) {
        switch (try routeModernRequest(st, a, req, protocol_header, method_header, name_header)) {
            .handled => return,
            .legacy => |body| legacy_body = body,
        }
    }

    var slot: ?*?Session = null;
    if (sid) |id| {
        for (&st.sessions) |*entry| if (entry.*) |s| {
            if (std.mem.eql(u8, &s.id, id)) {
                slot = entry;
                break;
            }
        };
        if (slot == null) return respond(req, .not_found, "{}", null);
    }

    if (req.head.method == .DELETE) {
        if (slot) |entry| entry.* = null else return respond(req, .bad_request, "{}", null);
        return respond(req, .no_content, "", null);
    }

    if (!json_type) return respond(req, .unsupported_media_type, "{}", null);
    const body = legacy_body orelse return respond(req, .bad_request, "{}", null);
    const value = std.json.parseFromSliceLeaky(Value, a, body, .{}) catch return respond(req, .bad_request, "{}", null);
    if (value != .object) return respond(req, .bad_request, "{}", null);
    const method = value.object.get("method") orelse return respond(req, .bad_request, "{}", null);
    const initializing = method == .string and std.mem.eql(u8, method.string, "initialize");

    var fresh = st.prototype;
    fresh.initialized = true;
    fresh.ready = true;
    const server = if (slot) |entry| &entry.*.?.server else blk: {
        if (initializing) fresh.initialized = false;
        break :blk &fresh;
    };

    var output: Io.Writer.Allocating = .init(a);
    try server.handle(a, &output.writer, body);

    var new_id: ?[]const u8 = null;
    if (slot == null and initializing and fresh.initialized) {
        var bytes: [16]u8 = undefined;
        st.io.random(&bytes);
        const id = std.fmt.bytesToHex(bytes, .lower);
        st.sessions[st.next] = .{ .id = id, .server = fresh };
        new_id = &st.sessions[st.next].?.id;
        st.next = (st.next + 1) % st.sessions.len;
    } else if (slot) |entry| {
        new_id = &entry.*.?.id;
    }
    return respond(req, if (output.written().len == 0) .accepted else .ok, output.written(), new_id);
}

const Routed = union(enum) { handled, legacy: []const u8 };

fn routeModernRequest(
    st: *HttpState,
    a: Allocator,
    req: *std.http.Server.Request,
    protocol_header: ?[]const u8,
    method_header: ?[]const u8,
    name_header: ?[]const u8,
) !Routed {
    const body = (try readBody(a, req)) orelse {
        try respond(req, .payload_too_large, "{}", null);
        return .handled;
    };
    const value = std.json.parseFromSliceLeaky(Value, a, body, .{}) catch return .{ .legacy = body };
    if (value != .object) return .{ .legacy = body };
    const params = value.object.get("params") orelse Value.null;
    const requested = mcp.requestedModernVersion(params) orelse return .{ .legacy = body };
    const id = value.object.get("id") orelse Value.null;
    var out: Io.Writer.Allocating = .init(a);
    if (!mcp.isModernSupported(requested)) {
        try mcp.writeUnsupported(&out.writer, id, requested);
        try respond(req, .bad_request, out.written(), null);
        return .handled;
    }
    if (mcp.headerMismatch(value, protocol_header, method_header, name_header)) |why| {
        try mcp.writeHeaderMismatch(&out.writer, id, why);
        try respond(req, .bad_request, out.written(), null);
        return .handled;
    }
    var fresh = st.prototype;
    try fresh.handle(a, &out.writer, body);
    try respond(req, if (out.written().len == 0) .accepted else .ok, out.written(), null);
    return .handled;
}

fn readBody(a: Allocator, req: *std.http.Server.Request) !?[]const u8 {
    if (req.head.content_length) |length| {
        if (length > 512 * 1024) return null;
    }
    var buffer: [4096]u8 = undefined;
    const body_reader = try req.readerExpectContinue(&buffer);
    return body_reader.allocRemaining(a, .limited(512 * 1024)) catch null;
}

pub fn equalToken(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

/// Runs the MCP server over stdio (`nanodocs mcp`).
pub fn runStdio(init: std.process.Init, prototype: mcp.Server) !void {
    var server = prototype;
    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(init.gpa);
    var rbuf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(0, &rbuf, rbuf.len);
        if (n <= 0) break;
        try line_buf.appendSlice(init.gpa, rbuf[0..@intCast(n)]);
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, line_buf.items, start, '\n')) |nl| {
            const line = std.mem.trimEnd(u8, line_buf.items[start..nl], "\r");
            start = nl + 1;
            var arena = std.heap.ArenaAllocator.init(init.gpa);
            defer arena.deinit();
            var out: Io.Writer.Allocating = .init(arena.allocator());
            try server.handle(arena.allocator(), &out.writer, line);
            if (out.written().len > 0) {
                _ = std.Io.File.stdout().writeStreamingAll(init.io, out.written()) catch break;
            }
        }
        const rest = line_buf.items.len - start;
        std.mem.copyForwards(u8, line_buf.items[0..rest], line_buf.items[start..]);
        line_buf.shrinkRetainingCapacity(rest);
    }
}
