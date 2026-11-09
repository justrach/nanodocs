//! Markdown and HTML document parser for `nanodocs`.
//!
//! Turns Markdown (`.md`, including embedded HTML such as `<p align="center">`,
//! `<img>`, `<details>`, `<table>`) and standalone HTML (`.html`) into blocks
//! and styled inline spans that `render.zig` lays out natively on the GPU.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const mm = @import("mermaid.zig");

pub const AlertKind = enum { blockquote, note, tip, important, warning, caution };

pub const Badge = struct {
    label: []const u8,
    value: []const u8,
    color: ui.Color,
};

pub const Cell = struct {
    text: []const u8,
    rich: ui.markdown.Rich = .{ .text = "", .spans = &.{} },
    image_src: []const u8 = "",
};

pub const HeadingEntry = struct {
    level: u8,
    text: []const u8,
    block_idx: usize,
};

pub const Block = union(enum) {
    heading: struct { level: u8, text: []const u8, centered: bool = false },
    paragraph: struct { text: []const u8, rich: ui.markdown.Rich, centered: bool = false, muted: bool = false },
    code: struct { lang: []const u8, text: []const u8 },
    mermaid: struct { source: []const u8, diagram: mm.Diagram },
    callout: struct { kind: AlertKind, title: []const u8, text: []const u8, rich: ui.markdown.Rich },
    list_item: struct { depth: u8, ordered: u16, checked: ?bool, text: []const u8, rich: ui.markdown.Rich },
    image: struct { src: []const u8, alt: []const u8, width: f32, centered: bool },
    badges: []const Badge,
    table: struct { headers: []const []const u8, rows: []const []const Cell },
    details: struct { summary: []const u8, body: []const Block },
    rule,
};

pub fn parseRich(a: std.mem.Allocator, text: []const u8) ui.markdown.Rich {
    return ui.markdown.parse(a, text, .{}) catch .{ .text = text, .spans = &.{} };
}

pub const Document = struct {
    title: []const u8,
    excerpt: []const u8,
    is_html: bool,
    blocks: []const Block,
    outline: []const HeadingEntry,
    word_count: usize,
};

pub fn parse(a: std.mem.Allocator, raw: []const u8, is_html: bool) Document {
    const src = if (is_html) htmlToMarkdown(a, raw) else raw;
    const blocks = parseBlocks(a, src);
    var title: []const u8 = "Untitled";
    var excerpt: []const u8 = "";
    var outline: std.ArrayList(HeadingEntry) = .empty;
    for (blocks, 0..) |b, idx| switch (b) {
        .heading => |h| {
            const clean = stripInline(a, h.text);
            if (std.mem.eql(u8, title, "Untitled") and clean.len > 0) title = clean;
            if (clean.len > 0) outline.append(a, .{ .level = h.level, .text = clean, .block_idx = idx }) catch {};
        },
        .paragraph => |p| if (excerpt.len == 0 and p.text.len > 12 and !p.muted) {
            excerpt = stripInline(a, p.text);
            if (excerpt.len > 110) excerpt = excerpt[0..110];
        },
        else => {},
    };
    return .{
        .title = title,
        .excerpt = excerpt,
        .is_html = is_html,
        .blocks = blocks,
        .outline = outline.items,
        .word_count = countWords(raw),
    };
}

fn countWords(s: []const u8) usize {
    var n: usize = 0;
    var in_word = false;
    for (s) |ch| {
        const ws = ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t';
        if (!ws and !in_word) n += 1;
        in_word = !ws;
    }
    return n;
}

fn parseBlocks(a: std.mem.Allocator, src: []const u8) []const Block {
    var out: std.ArrayList(Block) = .empty;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r ");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0) continue;

        if (std.mem.startsWith(u8, trimmed, "```")) {
            const lang = std.mem.trim(u8, trimmed[3..], " \t");
            var body: std.ArrayList(u8) = .empty;
            while (lines.next()) |cl| {
                const ct = std.mem.trimStart(u8, std.mem.trimEnd(u8, cl, "\r"), " \t");
                if (std.mem.startsWith(u8, ct, "```")) break;
                if (body.items.len > 0) body.append(a, '\n') catch {};
                body.appendSlice(a, std.mem.trimEnd(u8, cl, "\r")) catch {};
            }
            if (std.ascii.eqlIgnoreCase(lang, "mermaid")) {
                out.append(a, .{ .mermaid = .{ .source = body.items, .diagram = mm.parse(a, body.items) } }) catch {};
            } else {
                out.append(a, .{ .code = .{ .lang = lang, .text = body.items } }) catch {};
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "<details")) {
            var summary: []const u8 = "Details";
            var inner: std.ArrayList(u8) = .empty;
            while (lines.next()) |dl| {
                const dt = std.mem.trim(u8, dl, " \t\r");
                if (std.mem.startsWith(u8, dt, "</details>")) break;
                if (extractTag(dt, "summary")) |s| {
                    summary = stripInline(a, cleanHtmlInline(a, s));
                } else {
                    inner.appendSlice(a, dl) catch {};
                    inner.append(a, '\n') catch {};
                }
            }
            out.append(a, .{ .details = .{ .summary = summary, .body = parseBlocks(a, inner.items) } }) catch {};
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "<h1") or std.mem.startsWith(u8, trimmed, "<h2") or std.mem.startsWith(u8, trimmed, "<h3")) {
            const lvl: u8 = trimmed[2] - '0';
            const centered = std.mem.indexOf(u8, trimmed, "center") != null;
            const txt = stripInline(a, cleanHtmlInline(a, trimmed));
            if (txt.len > 0) out.append(a, .{ .heading = .{ .level = lvl, .text = txt, .centered = centered } }) catch {};
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "<p")) {
            const centered = std.mem.indexOf(u8, trimmed, "center") != null;
            var chunk: std.ArrayList(u8) = .empty;
            chunk.appendSlice(a, trimmed) catch {};
            while (std.mem.indexOf(u8, chunk.items, "</p>") == null) {
                const nl = lines.next() orelse break;
                chunk.append(a, ' ') catch {};
                chunk.appendSlice(a, std.mem.trim(u8, nl, " \t\r")) catch {};
            }
            parseHtmlParagraph(a, &out, chunk.items, centered);
            continue;
        }

        if (std.mem.eql(u8, trimmed, "---") or std.mem.eql(u8, trimmed, "***") or std.mem.startsWith(u8, trimmed, "<hr")) {
            out.append(a, .rule) catch {};
            continue;
        }

        if (trimmed[0] == '#') {
            var lvl: u8 = 0;
            while (lvl < trimmed.len and lvl < 4 and trimmed[lvl] == '#') lvl += 1;
            if (lvl < trimmed.len and trimmed[lvl] == ' ') {
                out.append(a, .{ .heading = .{ .level = lvl, .text = stripInline(a, cleanHtmlInline(a, std.mem.trim(u8, trimmed[lvl + 1 ..], " "))) } }) catch {};
                continue;
            }
        }

        if (std.mem.startsWith(u8, trimmed, "![")) {
            if (parseMdImage(trimmed)) |im| {
                out.append(a, .{ .image = .{ .src = im.src, .alt = im.alt, .width = 560, .centered = false } }) catch {};
                continue;
            }
        }

        if (trimmed[0] == '>') {
            var kind: AlertKind = .blockquote;
            var title: []const u8 = "";
            var first = std.mem.trimStart(u8, trimmed[1..], " ");
            if (std.mem.startsWith(u8, first, "[!")) {
                if (std.mem.indexOfScalar(u8, first, ']')) |close| {
                    const tag = first[2..close];
                    if (std.ascii.eqlIgnoreCase(tag, "NOTE")) {
                        kind = .note;
                        title = "Note";
                    } else if (std.ascii.eqlIgnoreCase(tag, "TIP")) {
                        kind = .tip;
                        title = "Tip";
                    } else if (std.ascii.eqlIgnoreCase(tag, "IMPORTANT")) {
                        kind = .important;
                        title = "Important";
                    } else if (std.ascii.eqlIgnoreCase(tag, "WARNING")) {
                        kind = .warning;
                        title = "Warning";
                    } else if (std.ascii.eqlIgnoreCase(tag, "CAUTION")) {
                        kind = .caution;
                        title = "Caution";
                    }
                    first = std.mem.trimStart(u8, first[close + 1 ..], " ");
                }
            }
            var qbody: std.ArrayList(u8) = .empty;
            if (first.len > 0) qbody.appendSlice(a, first) catch {};
            while (lines.peek()) |peek_raw| {
                const pt = std.mem.trimStart(u8, std.mem.trimEnd(u8, peek_raw, "\r "), " \t");
                if (pt.len == 0 or pt[0] != '>') break;
                _ = lines.next();
                const rest = std.mem.trimStart(u8, pt[1..], " ");
                if (qbody.items.len > 0) qbody.append(a, ' ') catch {};
                qbody.appendSlice(a, rest) catch {};
            }
            const ctext = cleanHtmlInline(a, qbody.items);
            out.append(a, .{ .callout = .{ .kind = kind, .title = title, .text = ctext, .rich = parseRich(a, ctext) } }) catch {};
            continue;
        }

        if (trimmed[0] == '|' and std.mem.count(u8, trimmed, "|") >= 2) {
            const raw_headers = splitTableRow(a, trimmed);
            var headers: std.ArrayList([]const u8) = .empty;
            for (raw_headers) |rh| headers.append(a, stripInline(a, rh)) catch {};
            var rows: std.ArrayList([]const Cell) = .empty;
            while (lines.peek()) |peek_raw| {
                const pt = std.mem.trim(u8, peek_raw, " \t\r");
                if (pt.len == 0 or pt[0] != '|') break;
                _ = lines.next();
                if (isSeparatorRow(pt)) continue;
                const cols = splitTableRow(a, pt);
                var cells: std.ArrayList(Cell) = .empty;
                for (cols) |c_txt| cells.append(a, .{ .text = c_txt, .rich = parseRich(a, c_txt) }) catch {};
                rows.append(a, cells.items) catch {};
            }
            out.append(a, .{ .table = .{ .headers = headers.items, .rows = rows.items } }) catch {};
            continue;
        }

        if (parseListMarker(line)) |lm| {
            const ltext = cleanHtmlInline(a, lm.rest);
            out.append(a, .{ .list_item = .{ .depth = lm.depth, .ordered = lm.ordered, .checked = lm.checked, .text = ltext, .rich = parseRich(a, ltext) } }) catch {};
            continue;
        }

        var para: std.ArrayList(u8) = .empty;
        para.appendSlice(a, cleanHtmlInline(a, trimmed)) catch {};
        while (lines.peek()) |peek_raw| {
            const pt = std.mem.trim(u8, peek_raw, " \t\r");
            if (pt.len == 0 or pt[0] == '#' or pt[0] == '>' or pt[0] == '|' or pt[0] == '<' or
                std.mem.startsWith(u8, pt, "```") or std.mem.startsWith(u8, pt, "---") or
                std.mem.startsWith(u8, pt, "![") or parseListMarker(peek_raw) != null) break;
            _ = lines.next();
            para.append(a, ' ') catch {};
            para.appendSlice(a, cleanHtmlInline(a, pt)) catch {};
        }
        if (para.items.len > 0) {
            out.append(a, .{ .paragraph = .{ .text = para.items, .rich = parseRich(a, para.items) } }) catch {};
        }
    }
    return out.items;
}

fn parseHtmlParagraph(a: std.mem.Allocator, out: *std.ArrayList(Block), html: []const u8, centered: bool) void {
    var badges: std.ArrayList(Badge) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, html, pos, "<img")) |img_start| {
        const img_end = std.mem.indexOfPos(u8, html, img_start, ">") orelse break;
        const tag = html[img_start .. img_end + 1];
        pos = img_end + 1;
        const src = attrValue(tag, "src") orelse "";
        const alt = attrValue(tag, "alt") orelse "";
        if (std.mem.indexOf(u8, src, "img.shields.io/badge/") != null) {
            badges.append(a, parseShieldBadge(a, src, alt)) catch {};
        } else if (src.len > 0) {
            const w_str = attrValue(tag, "width") orelse "520";
            const w = std.fmt.parseFloat(f32, std.mem.trimEnd(u8, w_str, "%px")) catch 480;
            const width_px: f32 = if (std.mem.endsWith(u8, w_str, "%")) @round(640.0 * (w / 100.0)) else w;
            out.append(a, .{ .image = .{ .src = src, .alt = alt, .width = width_px, .centered = centered } }) catch {};
        }
    }
    if (badges.items.len > 0) {
        out.append(a, .{ .badges = badges.items }) catch {};
        return;
    }
    const muted = std.mem.indexOf(u8, html, "<sub") != null;
    const txt = std.mem.trim(u8, cleanHtmlInline(a, html), " \t\r\n");
    if (txt.len > 0) {
        out.append(a, .{ .paragraph = .{ .text = txt, .rich = parseRich(a, txt), .centered = centered, .muted = muted } }) catch {};
    }
}

fn parseShieldBadge(a: std.mem.Allocator, src: []const u8, alt: []const u8) Badge {
    const marker = "badge/";
    const idx = (std.mem.indexOf(u8, src, marker) orelse return .{ .label = alt, .value = "", .color = .hex(0x3b82f6) }) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, src, idx, '?') orelse src.len;
    const raw = src[idx..end];
    const last_dash = std.mem.lastIndexOfScalar(u8, raw, '-') orelse return .{ .label = alt, .value = "", .color = .hex(0x555555) };
    const color_str = raw[last_dash + 1 ..];
    const body = urlDecode(a, raw[0..last_dash]);
    const color: ui.Color = if (std.mem.eql(u8, color_str, "44cc11"))
        .hex(0x2ea043)
    else if (std.mem.eql(u8, color_str, "f7a41d"))
        .hex(0xf7a41d)
    else if (std.mem.eql(u8, color_str, "blue"))
        .hex(0x2f6fd0)
    else if (std.mem.eql(u8, color_str, "5865F2"))
        .hex(0x5865f2)
    else
        .hex(0x57606a);
    if (std.mem.indexOfScalar(u8, body, '-')) |mid| {
        return .{ .label = body[0..mid], .value = body[mid + 1 ..], .color = color };
    }
    return .{ .label = body, .value = "", .color = color };
}

fn urlDecode(a: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                out.append(a, b) catch {};
                i += 2;
                continue;
            } else |_| {}
        }
        out.append(a, s[i]) catch {};
    }
    return out.items;
}

fn attrValue(tag: []const u8, attr: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < tag.len) {
        const idx = std.mem.indexOfPos(u8, tag, pos, attr) orelse return null;
        const after = idx + attr.len;
        if (after < tag.len and tag[after] == '=') {
            const q_start = after + 1;
            if (q_start < tag.len and (tag[q_start] == '"' or tag[q_start] == '\'')) {
                const q = tag[q_start];
                const q_end = std.mem.indexOfScalarPos(u8, tag, q_start + 1, q) orelse return null;
                return tag[q_start + 1 .. q_end];
            }
        }
        pos = after;
    }
    return null;
}

fn extractTag(s: []const u8, comptime tag: []const u8) ?[]const u8 {
    const open = "<" ++ tag ++ ">";
    const close = "</" ++ tag ++ ">";
    const a_idx = std.mem.indexOf(u8, s, open) orelse return null;
    const b_idx = std.mem.indexOfPos(u8, s, a_idx + open.len, close) orelse return null;
    return s[a_idx + open.len .. b_idx];
}

pub fn cleanHtmlInline(a: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var in_code = false;
    while (i < s.len) {
        if (s[i] == '`') {
            in_code = !in_code;
            out.append(a, '`') catch {};
            i += 1;
            continue;
        }
        if (!in_code and s[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, s, i, '>') orelse break;
            const tag = s[i + 1 .. end];
            if (std.mem.eql(u8, tag, "strong") or std.mem.eql(u8, tag, "/strong") or std.mem.eql(u8, tag, "b") or std.mem.eql(u8, tag, "/b")) {
                out.appendSlice(a, "**") catch {};
            } else if (std.mem.eql(u8, tag, "code") or std.mem.eql(u8, tag, "/code")) {
                out.append(a, '`') catch {};
            } else if (std.mem.eql(u8, tag, "em") or std.mem.eql(u8, tag, "/em") or std.mem.eql(u8, tag, "i") or std.mem.eql(u8, tag, "/i")) {
                out.append(a, '*') catch {};
            } else if (std.mem.startsWith(u8, tag, "br")) {
                out.append(a, '\n') catch {};
            }
            i = end + 1;
            continue;
        }
        if (std.mem.startsWith(u8, s[i..], "&quot;")) {
            out.append(a, '"') catch {};
            i += 6;
            continue;
        }
        if (std.mem.startsWith(u8, s[i..], "&amp;")) {
            out.append(a, '&') catch {};
            i += 5;
            continue;
        }
        if (std.mem.startsWith(u8, s[i..], "&lt;")) {
            out.append(a, '<') catch {};
            i += 4;
            continue;
        }
        if (std.mem.startsWith(u8, s[i..], "&gt;")) {
            out.append(a, '>') catch {};
            i += 4;
            continue;
        }
        out.append(a, s[i]) catch {};
        i += 1;
    }
    return flattenLinks(a, std.mem.trim(u8, out.items, " "));
}

/// Converts `[label](url)` into `**label**` so inline links render cleanly in `ui.markdown`.
pub fn flattenLinks(a: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, s, i + 1, ']')) |close| {
                if (close + 1 < s.len and s[close + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, s, close + 2, ')')) |pclose| {
                        const label = s[i + 1 .. close];
                        out.appendSlice(a, "**") catch {};
                        out.appendSlice(a, label) catch {};
                        out.appendSlice(a, "**") catch {};
                        i = pclose + 1;
                        continue;
                    }
                }
            }
        }
        out.append(a, s[i]) catch {};
        i += 1;
    }
    return out.items;
}

pub fn stripInline(a: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '*' or s[i] == '`') {
            i += 1;
            continue;
        }
        if (s[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, s, i + 1, ']')) |close| {
                if (close + 1 < s.len and s[close + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, s, close + 2, ')')) |pclose| {
                        out.appendSlice(a, s[i + 1 .. close]) catch {};
                        i = pclose + 1;
                        continue;
                    }
                }
            }
        }
        out.append(a, s[i]) catch {};
        i += 1;
    }
    return out.items;
}

fn parseMdImage(s: []const u8) ?struct { alt: []const u8, src: []const u8 } {
    const close_b = std.mem.indexOfScalar(u8, s, ']') orelse return null;
    if (close_b + 1 >= s.len or s[close_b + 1] != '(') return null;
    const close_p = std.mem.indexOfScalarPos(u8, s, close_b + 2, ')') orelse return null;
    return .{ .alt = s[2..close_b], .src = s[close_b + 2 .. close_p] };
}

fn isSeparatorRow(s: []const u8) bool {
    for (s) |ch| {
        if (ch != '|' and ch != '-' and ch != ':' and ch != ' ' and ch != '\t') return false;
    }
    return std.mem.indexOfScalar(u8, s, '-') != null;
}

fn splitTableRow(a: std.mem.Allocator, row: []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const inner = std.mem.trim(u8, row, "| ");
    var it = std.mem.splitScalar(u8, inner, '|');
    while (it.next()) |cell| {
        out.append(a, cleanHtmlInline(a, std.mem.trim(u8, cell, " \t"))) catch {};
    }
    return out.items;
}

const ListMatch = struct { depth: u8, ordered: u16, checked: ?bool, rest: []const u8 };

fn parseListMarker(line: []const u8) ?ListMatch {
    var spaces: usize = 0;
    while (spaces < line.len and line[spaces] == ' ') spaces += 1;
    const depth: u8 = @intCast(@min(spaces / 2, 4));
    const s = line[spaces..];
    if (s.len >= 2 and (s[0] == '-' or s[0] == '*' or s[0] == '+') and s[1] == ' ') {
        const after = std.mem.trimStart(u8, s[2..], " ");
        if (std.mem.startsWith(u8, after, "[ ] ")) return .{ .depth = depth, .ordered = 0, .checked = false, .rest = after[4..] };
        if (std.mem.startsWith(u8, after, "[x] ") or std.mem.startsWith(u8, after, "[X] ")) return .{ .depth = depth, .ordered = 0, .checked = true, .rest = after[4..] };
        return .{ .depth = depth, .ordered = 0, .checked = null, .rest = after };
    }
    var d: usize = 0;
    while (d < s.len and std.ascii.isDigit(s[d])) d += 1;
    if (d > 0 and d + 1 < s.len and s[d] == '.' and s[d + 1] == ' ') {
        const num = std.fmt.parseInt(u16, s[0..d], 10) catch 1;
        return .{ .depth = depth, .ordered = num, .checked = null, .rest = std.mem.trimStart(u8, s[d + 2 ..], " ") };
    }
    return null;
}

fn htmlToMarkdown(a: std.mem.Allocator, html: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < html.len) {
        if (std.mem.startsWith(u8, html[i..], "<style") or std.mem.startsWith(u8, html[i..], "<script") or std.mem.startsWith(u8, html[i..], "<head")) {
            const close_tag = if (html[i + 1] == 'h') "</head>" else if (html[i + 2] == 't') "</style>" else "</script>";
            if (std.mem.indexOfPos(u8, html, i, close_tag)) |end| {
                i = end + close_tag.len;
                continue;
            }
        }
        if (std.mem.startsWith(u8, html[i..], "<h1")) {
            out.appendSlice(a, "\n# ") catch {};
            i = (std.mem.indexOfScalarPos(u8, html, i, '>') orelse i) + 1;
            continue;
        }
        if (std.mem.startsWith(u8, html[i..], "<h2")) {
            out.appendSlice(a, "\n## ") catch {};
            i = (std.mem.indexOfScalarPos(u8, html, i, '>') orelse i) + 1;
            continue;
        }
        if (std.mem.startsWith(u8, html[i..], "<h3")) {
            out.appendSlice(a, "\n### ") catch {};
            i = (std.mem.indexOfScalarPos(u8, html, i, '>') orelse i) + 1;
            continue;
        }
        if (std.mem.startsWith(u8, html[i..], "<p>") or std.mem.startsWith(u8, html[i..], "<p ") or
            std.mem.startsWith(u8, html[i..], "</h") or std.mem.startsWith(u8, html[i..], "</p>") or
            std.mem.startsWith(u8, html[i..], "</div>") or std.mem.startsWith(u8, html[i..], "</li>") or
            std.mem.startsWith(u8, html[i..], "<ul") or std.mem.startsWith(u8, html[i..], "</ul>") or
            std.mem.startsWith(u8, html[i..], "<ol") or std.mem.startsWith(u8, html[i..], "</ol>") or
            std.mem.startsWith(u8, html[i..], "<body") or std.mem.startsWith(u8, html[i..], "</body>") or
            std.mem.startsWith(u8, html[i..], "<html") or std.mem.startsWith(u8, html[i..], "</html>") or
            std.mem.startsWith(u8, html[i..], "<!DOCTYPE"))
        {
            out.appendSlice(a, "\n\n") catch {};
            i = (std.mem.indexOfScalarPos(u8, html, i, '>') orelse i) + 1;
            continue;
        }
        if (std.mem.startsWith(u8, html[i..], "<li")) {
            out.appendSlice(a, "\n- ") catch {};
            i = (std.mem.indexOfScalarPos(u8, html, i, '>') orelse i) + 1;
            continue;
        }
        if (std.mem.startsWith(u8, html[i..], "<pre")) {
            const close_bracket = std.mem.indexOfScalarPos(u8, html, i, '>') orelse i;
            const open_tag = html[i .. close_bracket + 1];
            if (std.mem.indexOf(u8, open_tag, "mermaid") != null) {
                out.appendSlice(a, "\n```mermaid\n") catch {};
            } else {
                out.appendSlice(a, "\n```\n") catch {};
            }
            i = close_bracket + 1;
            continue;
        }
        if (std.mem.startsWith(u8, html[i..], "</pre>")) {
            out.appendSlice(a, "\n```\n") catch {};
            i += 6;
            continue;
        }
        out.append(a, html[i]) catch {};
        i += 1;
    }
    return out.items;
}
