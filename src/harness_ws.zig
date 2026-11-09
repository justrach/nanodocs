//! Loopback RFC 6455 WebSocket transport (`ws://127.0.0.1:27664`, no `Origin`
//! header) and local `.mcp.json` / `harness headless` helpers for `nanodocs`.
const std = @import("std");
const Io = std.Io;
const net = Io.net;

/// Minimal loopback RFC 6455 WebSocket client (`127.0.0.1:port`, no `Origin` header).
pub const WsClient = struct {
    io: Io,
    stream: net.Stream,
    rd: net.Stream.Reader,
    wr: net.Stream.Writer,
    rbuf: [16384]u8 = undefined,
    wbuf: [8192]u8 = undefined,

    pub fn connect(io: Io, port: u16) !WsClient {
        const addr = try net.IpAddress.parseIp4("127.0.0.1", port);
        const stream = try addr.connect(io, .{ .mode = .stream });
        var self: WsClient = .{ .io = io, .stream = stream, .rd = undefined, .wr = undefined };
        self.rd = net.Stream.Reader.init(stream, io, &self.rbuf);
        self.wr = net.Stream.Writer.init(stream, io, &self.wbuf);
        errdefer self.stream.close(io);

        var key_raw: [16]u8 = undefined;
        io.random(&key_raw);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &key_raw);
        try self.wr.interface.print(
            "GET / HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
            .{ port, &key },
        );
        try self.wr.interface.flush();
        const status = try self.rd.interface.takeDelimiterInclusive('\n');
        if (std.mem.indexOf(u8, status, " 101 ") == null) return error.HandshakeFailed;
        while (true) {
            const line = try self.rd.interface.takeDelimiterInclusive('\n');
            if (line.len <= 2) break;
        }
        return self;
    }

    pub fn close(self: *WsClient) void {
        self.stream.close(self.io);
    }

    pub fn sendText(self: *WsClient, payload: []const u8) !void {
        var mask: [4]u8 = undefined;
        self.io.random(&mask);
        var hdr: [14]u8 = undefined;
        hdr[0] = 0x81; // FIN + text
        var n: usize = 2;
        if (payload.len < 126) {
            hdr[1] = 0x80 | @as(u8, @intCast(payload.len));
        } else if (payload.len <= 0xffff) {
            hdr[1] = 0x80 | 126;
            std.mem.writeInt(u16, hdr[2..4], @intCast(payload.len), .big);
            n = 4;
        } else {
            hdr[1] = 0x80 | 127;
            std.mem.writeInt(u64, hdr[2..10], @intCast(payload.len), .big);
            n = 10;
        }
        @memcpy(hdr[n .. n + 4], &mask);
        n += 4;
        try self.wr.interface.writeAll(hdr[0..n]);
        for (payload, 0..) |b, i| {
            try self.wr.interface.writeByte(b ^ mask[i & 3]);
        }
        try self.wr.interface.flush();
    }

    pub fn readText(self: *WsClient, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        out.clearRetainingCapacity();
        while (true) {
            const h = try self.rd.interface.takeArray(2);
            const fin = (h[0] & 0x80) != 0;
            const op = h[0] & 0x0f;
            const masked = (h[1] & 0x80) != 0;
            var len: u64 = h[1] & 0x7f;
            if (len == 126) {
                len = std.mem.readInt(u16, try self.rd.interface.takeArray(2), .big);
            } else if (len == 127) {
                len = std.mem.readInt(u64, try self.rd.interface.takeArray(8), .big);
            }
            var mask: [4]u8 = .{ 0, 0, 0, 0 };
            if (masked) mask = (try self.rd.interface.takeArray(4)).*;
            if (op == 0x8) return error.PeerClosed;
            if (op == 0x9 or op == 0xA) {
                try self.rd.interface.discardAll(@intCast(len));
                continue;
            }
            const start = out.items.len;
            try out.resize(gpa, start + @as(usize, @intCast(len)));
            try self.rd.interface.readSliceAll(out.items[start..]);
            if (masked) {
                for (out.items[start..], 0..) |*b, i| b.* ^= mask[i & 3];
            }
            if (fin) return;
        }
    }
};

pub fn isPortListening(io: Io, port: u16) bool {
    const addr = net.IpAddress.parseIp4("127.0.0.1", port) catch return false;
    const s = addr.connect(io, .{ .mode = .stream }) catch return false;
    s.close(io);
    return true;
}

pub fn startHeadlessEngine(gpa: std.mem.Allocator, io: Io) void {
    const candidates = [_][]const u8{
        "/Applications/Harness.app/Contents/MacOS/harness",
        "harness",
    };
    for (candidates) |bin| {
        if (std.process.spawn(io, .{
            .argv = &.{ bin, "headless" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .pgid = 0,
        })) |_| return else |_| {}
    }
    _ = gpa;
}

pub fn hasNanodocsInMcpJson(gpa: std.mem.Allocator, io: Io, root_dir: []const u8) bool {
    var buf: [256]u8 = undefined;
    const p = if (std.mem.eql(u8, root_dir, "."))
        ".mcp.json"
    else
        (std.fmt.bufPrint(&buf, "{s}/.mcp.json", .{root_dir}) catch return false);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(256 * 1024)) catch return false;
    defer gpa.free(bytes);
    return std.mem.indexOf(u8, bytes, "\"nanodocs\"") != null;
}

pub fn wireMcpJson(gpa: std.mem.Allocator, io: Io, root_dir: []const u8, mcp_port: u16) void {
    var buf: [256]u8 = undefined;
    const p = if (std.mem.eql(u8, root_dir, "."))
        ".mcp.json"
    else
        (std.fmt.bufPrint(&buf, "{s}/.mcp.json", .{root_dir}) catch return);
    if (hasNanodocsInMcpJson(gpa, io, root_dir)) return;

    var exe_buf: [1024]u8 = undefined;
    const exe_len = std.process.executablePath(io, &exe_buf) catch 0;
    const exe_str = if (exe_len > 0) exe_buf[0..exe_len] else "nanodocs";

    const content = std.fmt.allocPrint(
        gpa,
        \\{{
        \\  "mcpServers": {{
        \\    "nanodocs": {{
        \\      "type": "http",
        \\      "url": "http://127.0.0.1:{d}/mcp",
        \\      "command": "{s}",
        \\      "args": ["mcp"]
        \\    }}
        \\  }}
        \\}}
        \\
    ,
        .{ mcp_port, exe_str },
    ) catch return;
    defer gpa.free(content);

    const f = std.Io.Dir.cwd().createFile(io, p, .{ .truncate = true }) catch return;
    defer f.close(io);
    f.writeStreamingAll(io, content) catch {};
}

pub fn resolveCwd(io: Io, root_dir: []const u8, out: *[512]u8) []const u8 {
    if (!std.mem.eql(u8, root_dir, ".")) return root_dir;
    const n = std.Io.Dir.cwd().realPathFile(io, ".", out) catch return ".";
    return out[0..n];
}

pub fn makeUuid(io: Io, out: *[36]u8) void {
    var b: [16]u8 = undefined;
    io.random(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    _ = std.fmt.bufPrint(
        out,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{ b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15] },
    ) catch {};
}

pub fn writeJsonStr(w: *Io.Writer, s: []const u8) !void {
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
