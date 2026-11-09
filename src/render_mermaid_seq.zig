//! Native GPU sequence diagram renderer for `nanodocs`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const mm = @import("mermaid.zig");
const render = @import("render.zig");
const v = @import("render_mermaid.zig");

pub fn seq(c: *ui.Context, s: mm.Seq, pal: render.Palette) void {
    const a = c.alloc();
    const n = s.actors.len;
    const widths = a.alloc(f32, n) catch return;
    const centers = a.alloc(f32, n) catch return;
    const box_h: f32 = 34;
    for (s.actors, widths) |actor, *w| w.* = @max(v.measure(c, actor.label, v.label_style)[0] + 28, 64);

    var x: f32 = 12 + widths[0] / 2;
    for (centers, 0..) |*cx, i| {
        if (i > 0) x += @max(widths[i - 1] / 2 + 36 + widths[i] / 2, 120);
        cx.* = x;
    }
    for (s.steps) |step| switch (step) {
        .message => |m| if (m.from != m.to and m.from < n and m.to < n) {
            const lo = @min(m.from, m.to);
            const hi = @max(m.from, m.to);
            const need = v.measure(c, m.text, v.small_style)[0] + 36;
            const have = centers[hi] - centers[lo];
            if (have < need) for (centers[hi..]) |*cx| {
                cx.* += need - have;
            };
        },
        .note => |nt| if (nt.from == nt.to and nt.side != .over and nt.from < n) {
            const need = v.measure(c, nt.text, v.small_style)[0] + 40;
            const i = nt.from;
            if (nt.side == .right and i + 1 < n and centers[i + 1] - centers[i] < need) {
                const d = need - (centers[i + 1] - centers[i]);
                for (centers[i + 1 ..]) |*cx| cx.* += d;
            }
        },
        else => {},
    };

    var y: f32 = 12 + box_h + 14;
    const rows = a.alloc(f32, s.steps.len) catch return;
    for (s.steps, rows) |step, *row| {
        row.* = y;
        y += switch (step) {
            .message => |m| v.measure(c, m.text, v.small_style)[1] + (if (m.from == m.to) @as(f32, 36) else 20),
            .note => |nt| v.measure(c, nt.text, v.small_style)[1] + 22,
            .section => 26,
        };
    }
    const bottom = y + 6;
    const W = centers[n - 1] + widths[n - 1] / 2 + 12 + 48;
    const H = bottom + box_h + 12;

    const outer = ui.div(c).row().wFull().justifyCenter();
    defer outer.end();
    const canvas = ui.div(c).w(W).h(H);
    defer canvas.end();

    const ink = pal.muted;
    const edge_strong = pal.border.mix(pal.ink, 0.22);
    var small_ink = v.small_style;
    small_ink.color = pal.ink;

    for (centers) |cx| v.line(c, cx, 12 + box_h, cx, bottom, .dotted, edge_strong);
    for (s.steps, rows) |step, row| switch (step) {
        .message => |m| {
            if (m.from >= n or m.to >= n) continue;
            const sz = v.measure(c, m.text, v.small_style);
            const x0 = centers[m.from];
            const x1 = centers[m.to];
            const kind: mm.Line = if (m.dashed) .dotted else .solid;
            if (m.from == m.to) {
                const ly = row + sz[1] + 4;
                v.line(c, x0, ly, x0 + 30, ly, kind, ink);
                v.line(c, x0 + 30, ly, x0 + 30, ly + 16, kind, ink);
                v.line(c, x0 + 30, ly + 16, x0, ly + 16, kind, ink);
                if (m.head) v.arrow(c, x0, ly + 16, .left, ink);
                v.label(c, x0 + 6, row, sz[0] + 8, sz[1], m.text, small_ink);
            } else {
                const ly = row + sz[1] + 6;
                v.line(c, x0, ly, x1, ly, kind, ink);
                if (m.head) v.arrow(c, x1, ly, if (x1 > x0) .right else .left, ink);
                const mid = (x0 + x1) / 2;
                v.label(c, mid - sz[0] / 2 - 4, row, sz[0] + 8, sz[1], m.text, small_ink);
            }
        },
        .note => |nt| {
            if (nt.from >= n or nt.to >= n) continue;
            const sz = v.measure(c, nt.text, v.small_style);
            const w = sz[0] + 20;
            const h = sz[1] + 12;
            const nx = switch (nt.side) {
                .over => if (nt.from == nt.to) centers[nt.from] - w / 2 else centers[nt.from] - 20,
                .right => centers[nt.from] + 10,
                .left => centers[nt.from] - 10 - w,
            };
            const nw = if (nt.side == .over and nt.from != nt.to) centers[nt.to] - centers[nt.from] + 40 else w;
            const note_bg = pal.bg.mix(.hex(0xd97706), 0.12);
            const note_edge = pal.border.mix(.hex(0xd97706), 0.45);
            v.panel(c, nx, row + 2, nw, h, note_bg, note_edge, 5);
            v.label(c, nx, row + 2, nw, h, nt.text, small_ink);
        },
        .section => |text| {
            const sz = v.measure(c, text, v.small_style);
            v.rect(c, 12, row + 12, W - 24, 1, pal.border, 0);
            v.panel(c, 12, row + 3, sz[0] + 16, sz[1] + 4, pal.bg, edge_strong, 4);
            var st = v.small_style;
            st.weight = .semibold;
            st.color = pal.muted;
            v.label(c, 12, row + 3, sz[0] + 16, sz[1] + 4, text, st);
        },
    };
    for (s.actors, centers, widths) |actor, cx, w| {
        for ([_]f32{ 12, bottom }) |by| {
            v.panel(c, cx - w / 2, by, w, box_h, pal.bg, edge_strong, if (actor.person) box_h / 2 else 6);
            var st = v.label_style;
            st.weight = .semibold;
            st.color = pal.ink;
            v.label(c, cx - w / 2, by, w, box_h, actor.label, st);
        }
    }
}
