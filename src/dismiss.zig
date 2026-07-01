//! "Dismissed" patterns: substrings the user never wants to see again. Any
//! briefing item (repo, todo, PR, code-todo, …) whose text contains a dismissed
//! pattern is filtered out of both the human view and the AI context.

const std = @import("std");
const app = @import("app.zig");

fn path(ctx: *app.Context) ?[]const u8 {
    return std.fs.path.join(ctx.arena, &.{ ctx.paths.dir, "dismissed" }) catch null;
}

/// One numbered, dismissable item from the last shown brief.
pub const LastItem = struct { pattern: []const u8, label: []const u8 };

fn lastPath(ctx: *app.Context) ?[]const u8 {
    return std.fs.path.join(ctx.arena, &.{ ctx.paths.dir, "last_items" }) catch null;
}

/// Persist the numbered items from a brief so `jog dismiss <n>` can resolve them.
pub fn saveLast(ctx: *app.Context, items: []const LastItem) void {
    const p = lastPath(ctx) orelse return;
    var b: std.ArrayList(u8) = .empty;
    for (items) |it| {
        const line = std.fmt.allocPrint(ctx.arena, "{s}\t{s}\n", .{ it.pattern, it.label }) catch return;
        b.appendSlice(ctx.arena, line) catch return;
    }
    std.Io.Dir.cwd().createDirPath(ctx.io, ctx.paths.dir) catch return;
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = p, .data = b.items }) catch return;
}

/// Look up the n-th (1-based) item from the last shown brief.
pub fn getLast(ctx: *app.Context, n: u32) ?LastItem {
    if (n == 0) return null;
    const p = lastPath(ctx) orelse return null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, p, ctx.arena, .unlimited) catch return null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var i: u32 = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        i += 1;
        if (i == n) {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return .{ .pattern = line, .label = line };
            return .{ .pattern = line[0..tab], .label = line[tab + 1 ..] };
        }
    }
    return null;
}

pub fn load(ctx: *app.Context) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    const p = path(ctx) orelse return list.items;
    const bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, p, ctx.arena, .unlimited) catch return list.items;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len > 0) list.append(ctx.arena, t) catch break;
    }
    return list.items;
}

/// True if any pattern occurs (case-insensitively) in `text`.
pub fn matches(patterns: []const []const u8, text: []const u8) bool {
    for (patterns) |p| {
        if (containsIgnoreCase(text, p)) return true;
    }
    return false;
}

pub fn add(ctx: *app.Context, pattern: []const u8) !void {
    const p = path(ctx) orelse return error.NoPath;
    var existing = std.ArrayList(u8).empty;
    if (std.Io.Dir.cwd().readFileAlloc(ctx.io, p, ctx.arena, .unlimited)) |b| {
        try existing.appendSlice(ctx.arena, b);
        if (b.len > 0 and b[b.len - 1] != '\n') try existing.append(ctx.arena, '\n');
    } else |_| {}
    try existing.appendSlice(ctx.arena, pattern);
    try existing.append(ctx.arena, '\n');
    try std.Io.Dir.cwd().createDirPath(ctx.io, ctx.paths.dir);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = p, .data = existing.items });
}

pub fn clear(ctx: *app.Context) !void {
    const p = path(ctx) orelse return error.NoPath;
    try std.Io.Dir.cwd().createDirPath(ctx.io, ctx.paths.dir);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = p, .data = "" });
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}
