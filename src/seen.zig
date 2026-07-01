//! Tracks the last date each repo's briefing was shown, so the on-cd hook fires
//! at most once per repo per day. Stored as: repo_path \t YYYY-MM-DD

const std = @import("std");

const Entry = struct { repo: []const u8, date: []const u8 };

fn load(arena: std.mem.Allocator, io: std.Io, path: []const u8) []Entry {
    var list: std.ArrayList(Entry) = .empty;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch return list.items;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        list.append(arena, .{
            .repo = line[0..tab],
            .date = std.mem.trim(u8, line[tab + 1 ..], " \t\r"),
        }) catch break;
    }
    return list.items;
}

/// True if `repo` was already briefed on `today`.
pub fn briefedToday(arena: std.mem.Allocator, io: std.Io, path: []const u8, repo: []const u8, today: []const u8) bool {
    for (load(arena, io, path)) |e| {
        if (std.mem.eql(u8, e.repo, repo)) return std.mem.eql(u8, e.date, today);
    }
    return false;
}

/// Record that `repo` was briefed on `today` (insert or update).
pub fn mark(arena: std.mem.Allocator, io: std.Io, dir: []const u8, path: []const u8, repo: []const u8, today: []const u8) !void {
    var entries: std.ArrayList(Entry) = .empty;
    try entries.appendSlice(arena, load(arena, io, path));

    var updated = false;
    for (entries.items) |*e| {
        if (std.mem.eql(u8, e.repo, repo)) {
            e.date = today;
            updated = true;
        }
    }
    if (!updated) try entries.append(arena, .{ .repo = repo, .date = today });

    var b: std.ArrayList(u8) = .empty;
    for (entries.items) |e| {
        const line = try std.fmt.allocPrint(arena, "{s}\t{s}\n", .{ e.repo, e.date });
        try b.appendSlice(arena, line);
    }
    try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = b.items });
}
