//! `nanodocs`: native GPU Markdown (`.md`) and HTML (`.html`) studio and
//! agent artifact shelf built on `nanoui`.
const std = @import("std");
const nanoui = @import("nanoui");
const AppState = @import("app.zig").AppState;

pub fn main(init: std.process.Init) !void {
    var explicit_file: ?[]const u8 = null;
    var save_to_shelf: bool = false;
    var dark_start: bool = false;

    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--nanoui-")) continue;
        if (std.mem.eql(u8, arg, "--shelf")) {
            save_to_shelf = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dark")) {
            dark_start = true;
            continue;
        }
        explicit_file = arg;
    }

    const app = try nanoui.App.create(init, .{ .name = "nanodocs" });
    defer app.destroy();

    var state = AppState.init(init.gpa, init.io, explicit_file);
    defer state.deinit();
    if (dark_start) state.mode = .dark;

    if (save_to_shelf) {
        if (explicit_file) |f| {
            if (std.Io.Dir.cwd().readFileAlloc(init.io, f, init.gpa, .limited(4 << 20))) |bytes| {
                defer init.gpa.free(bytes);
                state.shelf.saveArtifact(f, bytes) catch {};
                state.shelf.reload(explicit_file);
            } else |_| {}
        }
    }

    _ = try app.newWindow(.{
        .title = "nanodocs — Markdown & Agent Shelf",
        .width = 1120,
        .height = 760,
        .min_width = 680,
        .min_height = 460,
        .title_bar = .hidden,
        .content = .{ .view = .init(&state, AppState.view) },
    });

    try app.run();
}
