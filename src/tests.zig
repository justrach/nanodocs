const std = @import("std");
const testing = std.testing;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const md = @import("markdown.zig");
const mm = @import("mermaid.zig");
const shelf = @import("shelf.zig");
const mcp = @import("mcp.zig");
const mcp_http = @import("mcp_http.zig");
const AppState = @import("app.zig").AppState;

test "markdown parser: headings, alerts, code, tables, task lists and mermaid" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc = md.parse(
        arena.allocator(),
        \\# nanodocs Studio
        \\
        \\A native **GPU** Markdown & HTML renderer.
        \\
        \\> [!TIP]
        \\> Built with Liquid Glass capsules.
        \\
        \\- [x] Parse GFM tables
        \\- [ ] Open in shelf
        \\
        \\| Metric | Value |
        \\| --- | --- |
        \\| Rebuild | 0.56 s |
        \\
        \\```mermaid
        \\flowchart LR
        \\  A([Agent]) -->|show| B[[nanodocs GPU]]
        \\```
        \\
        \\```zig
        \\const x: u32 = 42;
        \\```
    ,
        false,
    );
    try testing.expectEqualStrings("nanodocs Studio", doc.title);
    try testing.expectEqual(@as(usize, 1), doc.outline.len);
    try testing.expect(doc.blocks.len >= 7);
    var found_mermaid = false;
    for (doc.blocks) |b| {
        if (b == .mermaid) {
            found_mermaid = true;
            try testing.expect(b.mermaid.diagram == .flow);
            try testing.expectEqual(@as(usize, 2), b.mermaid.diagram.flow.nodes.len);
            try testing.expectEqual(@as(usize, 1), b.mermaid.diagram.flow.edges.len);
        }
    }
    try testing.expect(found_mermaid);
}

test "mermaid parser: flowcharts, sequence diagrams, state diagrams and pie charts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const seq = mm.parse(
        a,
        \\sequenceDiagram
        \\  participant A as Agent
        \\  participant U as User
        \\  A->>U: Visual Walkthrough
        \\  Note over A,U: Rendered at 120Hz
    );
    try testing.expect(seq == .seq);
    try testing.expectEqual(@as(usize, 2), seq.seq.actors.len);
    try testing.expectEqual(@as(usize, 2), seq.seq.steps.len);

    const st = mm.parse(
        a,
        \\stateDiagram-v2
        \\  [*] --> Active
        \\  Active --> [*]
    );
    try testing.expect(st == .flow);
    try testing.expectEqualStrings("STATE DIAGRAM", st.flow.kind_label);
    try testing.expectEqual(@as(usize, 3), st.flow.nodes.len);

    const pie = mm.parse(
        a,
        \\pie title Rebuild Breakdown
        \\  "App" : 52
        \\  "Runtime" : 48
    );
    try testing.expect(pie == .pie);
    try testing.expectEqualStrings("Rebuild Breakdown", pie.pie.title);
    try testing.expectEqual(@as(usize, 2), pie.pie.slices.len);
}

test "html parser: converts standalone HTML and <pre class=mermaid> into native blocks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc = md.parse(
        arena.allocator(),
        \\<!DOCTYPE html>
        \\<html><head><title>Ignored</title></head>
        \\<body>
        \\<h1>Agent Verification Report</h1>
        \\<p>All <strong>47 PRs</strong> audited and merged.</p>
        \\<pre class="mermaid">
        \\flowchart TD
        \\  Start --> Finish
        \\</pre>
        \\<ul><li>Zero C shims</li><li>Under 600 lines</li></ul>
        \\</body></html>
    ,
        true,
    );
    try testing.expect(doc.is_html);
    try testing.expectEqualStrings("Agent Verification Report", doc.title);
    var has_mermaid = false;
    for (doc.blocks) |b| if (b == .mermaid) {
        has_mermaid = true;
    };
    try testing.expect(has_mermaid);
}

test "env parser: reads Discord guild, invite and webhook from .env" {
    const cfg = shelf.parseEnvBytes(
        \\# Discord config
        \\DISCORD_GUILD_ID=1566720297040879660
        \\DISCORD_INVITE_URL=https://discord.gg/EmTpv7rmTA
        \\DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/123/abc
    ,
        ".env",
    );
    try testing.expectEqualStrings("1566720297040879660", cfg.guild_id);
    try testing.expectEqualStrings("https://discord.gg/EmTpv7rmTA", cfg.invite_url);
    try testing.expectEqualStrings("https://discord.com/api/webhooks/123/abc", cfg.webhook_url);
}

test "nanodocs UI renders Mermaid diagrams offscreen in Tester and switches modes" {
    var state = AppState.init(testing.allocator, testing.io, null);
    defer state.deinit();

    const v = ui.View.init(&state, AppState.view);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, v, .{ .width = 1120, .height = 760 });
    defer t.deinit();

    try testing.expect(t.containsText("nanodocs"));
    try testing.expect(t.containsText("MERMAID"));
    try testing.expect(t.containsText("Paper"));

    try t.clickText("Paper");
    try testing.expectEqual(@import("render.zig").CanvasMode.dark, state.mode);

    try t.clickText("Discord · .env");
    try testing.expect(state.show_env_panel);

    try t.clickText("MCP · :7740");
    try testing.expect(state.show_mcp_panel);
}

test "MCP server: legacy initialize, stateless 2026-07-28 discover, tools/list and render_mermaid" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var srv: mcp.Server = .{ .gpa = testing.allocator, .io = testing.io };
    var out: std.Io.Writer.Allocating = .init(a);

    // 1. Legacy initialize handshake
    try srv.handle(a, &out.writer, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\"}}");
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"protocolVersion\":\"2025-11-25\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"name\":\"nanodocs\"") != null);

    // 2. Stateless 2026-07-28 server/discover
    var out2: std.Io.Writer.Allocating = .init(a);
    try srv.handle(a, &out2.writer, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"server/discover\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}}}");
    try testing.expect(std.mem.indexOf(u8, out2.written(), "\"resultType\":\"complete\"") != null);
    try testing.expect(std.mem.indexOf(u8, out2.written(), "\"cacheScope\":\"public\"") != null);

    // 3. tools/list
    var out3: std.Io.Writer.Allocating = .init(a);
    try srv.handle(a, &out3.writer, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}");
    try testing.expect(std.mem.indexOf(u8, out3.written(), "\"render_mermaid\"") != null);
    try testing.expect(std.mem.indexOf(u8, out3.written(), "\"show_document\"") != null);

    // 4. tools/call render_mermaid
    var out4: std.Io.Writer.Allocating = .init(a);
    try srv.handle(a, &out4.writer, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"render_mermaid\",\"arguments\":{\"title\":\"MCP Test Flow\",\"diagram\":\"flowchart LR\\n  MCP --> GPU\"}}}");
    defer {
        std.Io.Dir.cwd().deleteFile(testing.io, ".nanoui/shelf/mcp-test-flow.md") catch {};
        std.Io.Dir.cwd().deleteFile(testing.io, "../../.nanoui/shelf/mcp-test-flow.md") catch {};
    }
    try testing.expect(std.mem.indexOf(u8, out4.written(), "Rendered FLOWCHART (2 nodes, 1 edges)") != null);
    try testing.expect(std.mem.indexOf(u8, out4.written(), "\"isError\":false") != null);

    // 5. Constant-time bearer check
    try testing.expect(mcp_http.equalToken("Bearer secret123", "Bearer secret123"));
    try testing.expect(!mcp_http.equalToken("Bearer secret123", "Bearer wrong1234"));
}
