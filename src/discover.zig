//! Auto-discovers git repos by walking the configured roots up to a bounded depth.
//! A directory containing `.git` is recorded as a repo and not descended into.

const std = @import("std");

const max_repos = 500;

const ignored_dirs = [_][]const u8{
    "node_modules", "vendor", "target", "build", "dist",
    ".venv",        "venv",   "__pycache__",
};

/// Returns absolute paths of discovered repos (arena-owned).
pub fn discover(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, roots: []const []const u8, depth: u32) []const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    for (roots) |root| {
        const abs = resolveTilde(arena, env, root) orelse root;
        walk(arena, io, abs, depth, &found);
    }
    return found.items;
}

fn walk(arena: std.mem.Allocator, io: std.Io, path: []const u8, depth_left: u32, found: *std.ArrayList([]const u8)) void {
    if (found.items.len >= max_repos) return;

    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    // If this directory is itself a repo, record it and stop descending.
    if (dir.access(io, ".git", .{})) |_| {
        found.append(arena, path) catch {};
        return;
    } else |_| {}

    if (depth_left == 0) return;

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (isIgnored(entry.name)) continue;
        const child = std.fs.path.join(arena, &.{ path, entry.name }) catch continue;
        walk(arena, io, child, depth_left - 1, found);
        if (found.items.len >= max_repos) return;
    }
}

fn isIgnored(name: []const u8) bool {
    for (ignored_dirs) |d| {
        if (std.mem.eql(u8, name, d)) return true;
    }
    return false;
}

/// Expands a leading "~/" to $HOME. Returns null if no expansion needed.
fn resolveTilde(arena: std.mem.Allocator, env: *std.process.Environ.Map, path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, "~/")) return null;
    const home = env.get("HOME") orelse return null;
    return std.fs.path.join(arena, &.{ home, path[2..] }) catch null;
}
