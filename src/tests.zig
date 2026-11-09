const std = @import("std");
const testing = std.testing;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const md = @import("markdown.zig");
const shelf = @import("shelf.zig");
const AppState = @import("app.zig").AppState;

test "markdown parser: headings, alerts, code, tables and task lists" {
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
        \\```zig
        \\const x: u32 = 42;
        \\```
    ,
        false,
    );
    try testing.expectEqualStrings("nanodocs Studio", doc.title);
    try testing.expectEqual(@as(usize, 1), doc.outline.len);
    try testing.expect(doc.blocks.len >= 6);
}

test "html parser: converts standalone HTML into native blocks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc = md.parse(
        arena.allocator(),
        \\<!DOCTYPE html>
        \\<html><head><title>Ignored</title></head>
        \\<body>
        \\<h1>Agent Verification Report</h1>
        \\<p>All <strong>47 PRs</strong> audited and merged.</p>
        \\<ul><li>Zero C shims</li><li>Under 600 lines</li></ul>
        \\</body></html>
    ,
        true,
    );
    try testing.expect(doc.is_html);
    try testing.expectEqualStrings("Agent Verification Report", doc.title);
    try testing.expect(doc.blocks.len >= 3);
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

test "nanodocs UI renders offscreen in Tester and switches modes" {
    var state = AppState.init(testing.allocator, testing.io, null);
    defer state.deinit();

    const v = ui.View.init(&state, AppState.view);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, v, .{ .width = 1120, .height = 760 });
    defer t.deinit();

    try testing.expect(t.containsText("nanodocs"));
    try testing.expect(t.containsText("Paper"));

    try t.clickText("Paper");
    try testing.expectEqual(@import("render.zig").CanvasMode.dark, state.mode);

    try t.clickText("Discord · .env");
    try testing.expect(state.show_env_panel);
}
