//! MCP server for `nanodocs` (both stateless `2026-07-28` and session-based
//! `2025-11-25` / `2025-06-18` / `2025-03-26` / `2024-11-05`), after
//! Codegraff's `mcp_server.zig` and `mcp_server_modern.zig`.
//!
//! Exposes `show_document`, `render_mermaid`, `list_shelf`, and `read_document`
//! over stdio (`nanodocs mcp`) and Streamable HTTP (`http://127.0.0.1:7740/mcp`).
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const md = @import("markdown.zig");
const mm = @import("mermaid.zig");
const shelf_mod = @import("shelf.zig");

pub const modern_version = "2026-07-28";
pub const supported_versions = [_][]const u8{
    modern_version,
    "2025-11-25",
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
};
pub const version_key = "io.modelcontextprotocol/protocolVersion";
pub const unsupported_code: i32 = -32022;
pub const header_mismatch_code: i32 = -32020;
pub const ttl_ms: u64 = 5 * 60 * 1000;

pub const resource_uri = "ui://nanodocs/shelf";
pub const resource_mime = "text/html;profile=mcp-app";

pub const instructions =
    \\nanodocs is a native GPU Markdown, HTML, and Mermaid studio built on nanoui.
    \\Use `show_document` or `render_mermaid` whenever you want to show the user a visual walkthrough,
    \\architecture diagram (flowchart, sequenceDiagram, stateDiagram-v2, classDiagram, erDiagram, pie),
    \\table, or HTML report. Documents are saved into `.nanoui/shelf/` and rendered at 120Hz on Metal/GPU
    \\with 0ms per-frame Mermaid parsing.
;

pub const NotifyFn = *const fn (ctx: ?*anyopaque, path: []const u8) void;

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    initialized: bool = false,
    ready: bool = false,
    on_show: ?NotifyFn = null,
    on_show_ctx: ?*anyopaque = null,
    spawn_window_on_call: bool = false,

    pub fn handle(self: *Server, a: Allocator, out: *Io.Writer, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return;
        const request = std.json.parseFromSliceLeaky(Value, a, trimmed, .{}) catch
            return failure(out, .null, -32700, "Parse error");
        if (request != .object) return failure(out, .null, -32600, "Invalid Request");
        const id = request.object.get("id") orelse Value.null;
        if (id != .null and id != .string and id != .integer)
            return failure(out, .null, -32600, "Invalid request id");
        const jsonrpc = string(request, "jsonrpc") orelse "";
        const method = string(request, "method") orelse "";
        if (!std.mem.eql(u8, jsonrpc, "2.0") or method.len == 0)
            return failure(out, id, -32600, "Invalid Request");

        // Notifications (notifications/initialized, notifications/cancelled) produce no response body
        if (!request.object.contains("id")) {
            if (self.initialized and std.mem.eql(u8, method, "notifications/initialized")) self.ready = true;
            return;
        }

        const params = request.object.get("params") orelse Value.null;
        const era = requestedModernVersion(params);
        if (era) |requested| {
            if (!isModernSupported(requested)) return writeUnsupported(out, id, requested);
        }

        if (std.mem.eql(u8, method, "ping")) {
            return sendAnswer(a, out, id, era != null, false, "{}");
        }
        if (std.mem.eql(u8, method, "server/discover")) {
            if (era == null) return failure(out, id, -32601, "Method not found");
            var aw: Io.Writer.Allocating = .init(a);
            try writeDiscover(&aw.writer);
            return sendAnswer(a, out, id, true, true, aw.written());
        }
        if (era == null and std.mem.eql(u8, method, "initialize")) {
            if (self.initialized) return failure(out, id, -32600, "Already initialized");
            const requested = string(params, "protocolVersion") orelse "2025-11-25";
            const protocol = for (supported_versions[1..]) |v| {
                if (std.mem.eql(u8, requested, v)) break v;
            } else supported_versions[1];
            self.initialized = true;
            self.ready = true; // allow immediate calls from lenient clients
            var aw: Io.Writer.Allocating = .init(a);
            try writeInitialize(&aw.writer, protocol);
            return sendAnswer(a, out, id, false, false, aw.written());
        }
        if (std.mem.eql(u8, method, "tools/list")) {
            var aw: Io.Writer.Allocating = .init(a);
            try writeToolsList(&aw.writer);
            return sendAnswer(a, out, id, era != null, true, aw.written());
        }
        if (std.mem.eql(u8, method, "resources/list")) {
            const res_json =
                \\{"resources":[{"uri":"ui://nanodocs/shelf","name":"nanodocs_shelf","title":"nanodocs Agent Shelf","description":"Native GPU Markdown, HTML and Mermaid shelf.","mimeType":"text/html;profile=mcp-app"}]}
            ;
            return sendAnswer(a, out, id, era != null, true, res_json);
        }
        if (std.mem.eql(u8, method, "resources/templates/list")) {
            return sendAnswer(a, out, id, era != null, true, "{\"resourceTemplates\":[]}");
        }
        if (std.mem.eql(u8, method, "resources/read")) {
            const uri = string(params, "uri") orelse return failure(out, id, -32602, "Resource URI is required");
            if (!std.mem.eql(u8, uri, resource_uri)) return failure(out, id, -32002, "Resource not found");
            const body_json =
                \\{"contents":[{"uri":"ui://nanodocs/shelf","mimeType":"text/html;profile=mcp-app","text":"<!doctype html><html><body><h1>nanodocs Agent Shelf</h1><p> Native GPU Markdown &amp; Mermaid studio.</p></body></html>"}]}
            ;
            return sendAnswer(a, out, id, era != null, true, body_json);
        }
        if (std.mem.eql(u8, method, "tools/call")) {
            return self.handleToolCall(a, out, id, era != null, params);
        }
        return failure(out, id, -32601, "Method not found");
    }

    fn handleToolCall(self: *Server, a: Allocator, out: *Io.Writer, id: Value, is_modern: bool, params: Value) !void {
        const name = string(params, "name") orelse return failure(out, id, -32602, "Tool name is required");
        const args = if (params == .object) (params.object.get("arguments") orelse Value.null) else Value.null;

        if (std.mem.eql(u8, name, "show_document")) {
            const title = string(args, "title") orelse "Agent Walkthrough";
            const markdown_src = string(args, "markdown");
            const html_src = string(args, "html");
            if (markdown_src == null and html_src == null) {
                return failure(out, id, -32602, "Provide either `markdown` or `html` content");
            }
            const is_html = html_src != null and markdown_src == null;
            const raw = if (is_html) html_src.? else markdown_src.?;

            const saved_path = shelf_mod.writeAgentNoteFast(self.io, a, null, ".nanoui/shelf", title, raw, is_html) catch |err| {
                const msg = try std.fmt.allocPrint(a, "Failed to save document: {s}", .{@errorName(err)});
                return writeToolResult(a, out, id, is_modern, msg, true);
            };
            const doc = md.parse(a, raw, is_html);
            var mermaid_count: usize = 0;
            for (doc.blocks) |b| if (b == .mermaid) {
                mermaid_count += 1;
            };
            if (self.on_show) |cb| cb(self.on_show_ctx, saved_path);
            const summary = try std.fmt.allocPrint(
                a,
                "Saved `{s}` ({d} words, {d} outline headings, {d} native GPU Mermaid diagrams) to `.nanoui/shelf/`.",
                .{ saved_path, doc.word_count, doc.outline.len, mermaid_count },
            );
            return writeToolResult(a, out, id, is_modern, summary, false);
        }

        if (std.mem.eql(u8, name, "render_mermaid")) {
            const diagram_src = string(args, "diagram") orelse return failure(out, id, -32602, "`diagram` (Mermaid source) is required");
            const title = string(args, "title") orelse "Mermaid Diagram";
            const explanation = string(args, "explanation") orelse "";
            const parsed = mm.parse(a, diagram_src);
            const kind_str = switch (parsed) {
                .flow => |f| f.kind_label,
                .seq => "SEQUENCE DIAGRAM",
                .pie => "PIE CHART",
                .other => "OTHER",
            };
            const full_md = if (explanation.len > 0)
                try std.fmt.allocPrint(a, "# {s}\n\n{s}\n\n```mermaid\n{s}\n```\n", .{ title, explanation, diagram_src })
            else
                try std.fmt.allocPrint(a, "# {s}\n\n```mermaid\n{s}\n```\n", .{ title, diagram_src });

            const saved_path = shelf_mod.writeAgentNoteFast(self.io, a, null, ".nanoui/shelf", title, full_md, false) catch |err| {
                const msg = try std.fmt.allocPrint(a, "Failed to write diagram: {s}", .{@errorName(err)});
                return writeToolResult(a, out, id, is_modern, msg, true);
            };
            if (self.on_show) |cb| cb(self.on_show_ctx, saved_path);

            const details = switch (parsed) {
                .flow => |f| try std.fmt.allocPrint(a, "Rendered {s} ({d} nodes, {d} edges) at `{s}`.", .{ kind_str, f.nodes.len, f.edges.len, saved_path }),
                .seq => |s| try std.fmt.allocPrint(a, "Rendered SEQUENCE DIAGRAM ({d} actors, {d} steps) at `{s}`.", .{ s.actors.len, s.steps.len, saved_path }),
                .pie => |p| try std.fmt.allocPrint(a, "Rendered PIE CHART ({d} slices) at `{s}`.", .{ p.slices.len, saved_path }),
                .other => |o| try std.fmt.allocPrint(a, "Saved Mermaid block ({s}) at `{s}`.", .{ o, saved_path }),
            };
            return writeToolResult(a, out, id, is_modern, details, false);
        }

        if (std.mem.eql(u8, name, "list_shelf")) {
            var sh = shelf_mod.Shelf.init(self.gpa, self.io);
            defer sh.deinit();
            sh.reload(null);
            var aw: Io.Writer.Allocating = .init(a);
            try aw.writer.print("Shelf directory: `{s}` ({d} documents)\n", .{ sh.env.shelf_dir, sh.entries.items.len });
            for (sh.entries.items) |e| {
                var mm_cnt: usize = 0;
                for (e.doc.blocks) |b| if (b == .mermaid) {
                    mm_cnt += 1;
                };
                try aw.writer.print("- `{s}` ({s}, {d} words, {d} mermaid diagrams)\n", .{
                    e.name,
                    if (e.in_shelf) "shelf" else "workspace",
                    e.doc.word_count,
                    mm_cnt,
                });
            }
            return writeToolResult(a, out, id, is_modern, aw.written(), false);
        }

        if (std.mem.eql(u8, name, "read_document")) {
            const target = string(args, "name") orelse string(args, "path") orelse return failure(out, id, -32602, "`name` or `path` is required");
            var sh = shelf_mod.Shelf.init(self.gpa, self.io);
            defer sh.deinit();
            sh.reload(null);
            for (sh.entries.items) |e| {
                if (std.mem.eql(u8, e.name, target) or std.mem.eql(u8, e.path, target)) {
                    return writeToolResult(a, out, id, is_modern, e.raw, false);
                }
            }
            return writeToolResult(a, out, id, is_modern, "Document not found in shelf or workspace.", true);
        }

        return failure(out, id, -32602, "Unknown tool");
    }
};

pub fn requestedModernVersion(params: Value) ?[]const u8 {
    if (params != .object) return null;
    const m = params.object.get("_meta") orelse return null;
    if (m != .object) return null;
    const v = m.object.get(version_key) orelse return null;
    return if (v == .string) v.string else null;
}

pub fn isModernSupported(requested: []const u8) bool {
    return std.mem.eql(u8, requested, modern_version);
}

pub fn headerMismatch(body: Value, protocol_header: ?[]const u8, method_header: ?[]const u8, name_header: ?[]const u8) ?[]const u8 {
    const params = if (body == .object) body.object.get("params") orelse Value.null else Value.null;
    const requested = requestedModernVersion(params) orelse return null;
    if (!std.mem.eql(u8, protocol_header orelse "", requested)) return "MCP-Protocol-Version header does not match _meta protocolVersion";
    const method = if (body == .object) body.object.get("method") orelse Value.null else Value.null;
    if (method != .string or !std.mem.eql(u8, method_header orelse "", method.string)) return "Mcp-Method header does not match the request method";
    if (std.mem.eql(u8, method.string, "tools/call")) {
        const v = if (params == .object) params.object.get("name") orelse Value.null else Value.null;
        if (v == .string and !std.mem.eql(u8, name_header orelse "", v.string)) return "Mcp-Name header does not match the request";
    }
    return null;
}

pub fn writeUnsupported(out: *Io.Writer, id: Value, requested: []const u8) !void {
    var json: std.json.Stringify = .{ .writer = out };
    try json.write(.{ .jsonrpc = "2.0", .id = id, .@"error" = .{
        .code = unsupported_code,
        .message = "Unsupported protocol version",
        .data = .{ .supported = supported_versions, .requested = requested },
    } });
    try out.writeByte('\n');
}

pub fn writeHeaderMismatch(out: *Io.Writer, id: Value, why: []const u8) !void {
    var json: std.json.Stringify = .{ .writer = out };
    try json.write(.{ .jsonrpc = "2.0", .id = id, .@"error" = .{
        .code = header_mismatch_code,
        .message = why,
    } });
    try out.writeByte('\n');
}

fn writeInitialize(w: *Io.Writer, protocol: []const u8) !void {
    try w.print("{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{\"listChanged\":false}},\"resources\":{{\"listChanged\":false}}}},\"serverInfo\":{{\"name\":\"nanodocs\",\"version\":\"0.2.0\"}},\"instructions\":", .{protocol});
    try std.json.Stringify.encodeJsonString(instructions, .{}, w);
    try w.writeByte('}');
}

fn writeDiscover(w: *Io.Writer) !void {
    try w.writeAll("{\"supportedVersions\":[\"2026-07-28\",\"2025-11-25\",\"2025-06-18\",\"2025-03-26\",\"2024-11-05\"],\"capabilities\":{\"tools\":{\"listChanged\":false},\"resources\":{\"listChanged\":false}},\"serverInfo\":{\"name\":\"nanodocs\",\"version\":\"0.2.0\"},\"instructions\":");
    try std.json.Stringify.encodeJsonString(instructions, .{}, w);
    try w.writeByte('}');
}

pub fn writeToolsList(w: *Io.Writer) !void {
    try w.writeAll(
        \\{"tools":[
        \\{"name":"show_document","title":"Show Markdown or HTML in nanodocs","description":"Saves a Markdown (.md) or HTML (.html) walkthrough (with native 120Hz GPU Mermaid diagrams, tables, and callouts) into .nanoui/shelf/ and displays it in nanodocs.","inputSchema":{"type":"object","properties":{"title":{"type":"string","description":"Document title"},"markdown":{"type":"string","description":"Markdown body (supports ```mermaid blocks: flowchart, sequenceDiagram, stateDiagram-v2, classDiagram, erDiagram, pie)"},"html":{"type":"string","description":"Standalone HTML body (supports <pre class=\"mermaid\">)"}},"required":["title"]},"annotations":{"readOnlyHint":false}},
        \\{"name":"render_mermaid","title":"Render Native GPU Mermaid Diagram","description":"Pre-parses and renders a Mermaid diagram (flowchart TD/LR, sequenceDiagram, stateDiagram-v2, classDiagram, erDiagram, pie) natively on the GPU in nanodocs with 0ms per-frame parsing.","inputSchema":{"type":"object","properties":{"title":{"type":"string","description":"Diagram title"},"diagram":{"type":"string","description":"Mermaid diagram source (e.g. flowchart LR, sequenceDiagram, stateDiagram-v2, pie)"},"explanation":{"type":"string","description":"Optional Markdown explanation accompanying the diagram"}},"required":["diagram"]},"annotations":{"readOnlyHint":false}},
        \\{"name":"list_shelf","title":"List Agent Shelf Documents","description":"Lists all Markdown and HTML artifacts in .nanoui/shelf/ and workspace documents.","inputSchema":{"type":"object","properties":{}},"annotations":{"readOnlyHint":true}},
        \\{"name":"read_document","title":"Read Document from Shelf","description":"Reads the source of a document in .nanoui/shelf/ or the workspace by name or path.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Document filename or path"}},"required":["name"]},"annotations":{"readOnlyHint":true}}
        \\]}
    );
}

fn writeToolResult(a: Allocator, out: *Io.Writer, id: Value, is_modern: bool, text: []const u8, is_error: bool) !void {
    var aw: Io.Writer.Allocating = .init(a);
    try aw.writer.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
    try std.json.Stringify.encodeJsonString(text, .{}, &aw.writer);
    try aw.writer.print("}}],\"isError\":{}}}", .{is_error});
    return sendAnswer(a, out, id, is_modern, false, aw.written());
}

fn sendAnswer(a: Allocator, out: *Io.Writer, id: Value, is_modern: bool, cacheable: bool, result_json: []const u8) !void {
    const id_str = try std.json.Stringify.valueAlloc(a, id, .{});
    if (!is_modern) {
        try out.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}\n", .{ id_str, result_json });
        return;
    }
    // Modern 2026-07-28 envelope: inject resultType (+ ttlMs/cacheScope when cacheable)
    const trimmed = std.mem.trimEnd(u8, result_json, " \t\r\n");
    if (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') {
        const inner = trimmed[1 .. trimmed.len - 1];
        const comma = if (inner.len > 0) "," else "";
        if (cacheable) {
            try out.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{{s}{s}\"resultType\":\"complete\",\"ttlMs\":{d},\"cacheScope\":\"public\"}}}}\n", .{ id_str, inner, comma, ttl_ms });
        } else {
            try out.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{{s}{s}\"resultType\":\"complete\"}}}}\n", .{ id_str, inner, comma });
        }
    } else {
        try out.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}\n", .{ id_str, result_json });
    }
}

pub fn failure(out: *Io.Writer, id: Value, code: i32, message: []const u8) !void {
    var json: std.json.Stringify = .{ .writer = out };
    try json.write(.{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } });
    try out.writeByte('\n');
}

fn string(value: Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}
