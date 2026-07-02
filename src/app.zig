//! Shared application context and tiny output helpers used across commands.

const std = @import("std");
const config_mod = @import("config.zig");
const paths_mod = @import("paths.zig");
const ui = @import("ui.zig");

pub const Context = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    paths: paths_mod.Paths,
    cfg: config_mod.Config,
    theme: ui.Theme = .{},
};

/// Small growable string builder over an arena, used to assemble output before a
/// single write to stdout.
pub const Buf = struct {
    arena: std.mem.Allocator,
    list: std.ArrayList(u8),

    pub fn init(arena: std.mem.Allocator) Buf {
        return .{ .arena = arena, .list = .empty };
    }
    pub fn append(self: *Buf, s: []const u8) !void {
        try self.list.appendSlice(self.arena, s);
    }
    pub fn printf(self: *Buf, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.arena, fmt, args);
        try self.list.appendSlice(self.arena, s);
    }
    pub fn items(self: *Buf) []const u8 {
        return self.list.items;
    }
    pub fn len(self: *Buf) usize {
        return self.list.items.len;
    }
};

/// Write a finished buffer to stdout in one shot.
pub fn writeOut(io: std.Io, bytes: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    try fw.interface.writeAll(bytes);
    try fw.interface.flush();
}

/// Transient status on stderr (overwrites the current line). No-op when stderr
/// isn't a terminal, so it never pollutes piped output.
pub fn note(io: std.Io, msg: []const u8) void {
    const f = std.Io.File.stderr();
    if (!(f.isTty(io) catch false)) return;
    var buf: [256]u8 = undefined;
    var fw = f.writer(io, &buf);
    fw.interface.print("\r\x1b[2K\x1b[2m{s}\x1b[0m", .{msg}) catch {};
    fw.interface.flush() catch {};
}

/// Clear the transient status line written by `note`.
pub fn clearNote(io: std.Io) void {
    const f = std.Io.File.stderr();
    if (!(f.isTty(io) catch false)) return;
    var buf: [16]u8 = undefined;
    var fw = f.writer(io, &buf);
    fw.interface.writeAll("\r\x1b[2K") catch {};
    fw.interface.flush() catch {};
}
