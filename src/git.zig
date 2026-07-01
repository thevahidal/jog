//! Per-repo git facts, gathered by shelling out to `git`. Everything tolerates
//! failure (non-zero exit, missing upstream, …) by treating it as "none".

const std = @import("std");

pub const RepoFacts = struct {
    path: []const u8,
    name: []const u8,
    branch: []const u8, // "" when unknown/detached
    commits: []const []const u8, // "hash subject" lines, newest first
    dirty: u32, // changed paths in working tree
    unpushed: u32, // commits ahead of upstream
    stashes: u32,

    pub fn hasActivity(self: RepoFacts) bool {
        return self.commits.len > 0 or self.dirty > 0 or self.unpushed > 0 or self.stashes > 0;
    }
};

/// Run `git <args>` inside `repo`; returns trimmed stdout, or null on any failure
/// or non-zero exit. Memory comes from `arena`.
pub fn run(arena: std.mem.Allocator, io: std.Io, repo: []const u8, args: []const []const u8) ?[]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(arena, "git") catch return null;
    argv.appendSlice(arena, args) catch return null;

    const res = std.process.run(arena, io, .{
        .argv = argv.items,
        .cwd = .{ .path = repo },
    }) catch return null;

    switch (res.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    return std.mem.trim(u8, res.stdout, " \t\r\n");
}

/// Gather all facts for a single repo.
pub fn facts(arena: std.mem.Allocator, io: std.Io, repo: []const u8, days: u32, max_commits: u32) RepoFacts {
    const branch = run(arena, io, repo, &.{ "rev-parse", "--abbrev-ref", "HEAD" }) orelse "";

    const since = std.fmt.allocPrint(arena, "--since={d}.days", .{days}) catch "--since=7.days";
    const max = std.fmt.allocPrint(arena, "{d}", .{max_commits}) catch "5";
    const commits = blk: {
        const out = run(arena, io, repo, &.{ "log", since, "--pretty=%h %s", "-n", max }) orelse break :blk &[_][]const u8{};
        break :blk splitLines(arena, out);
    };

    const dirty = countLines(run(arena, io, repo, &.{ "status", "--porcelain" }));
    const unpushed = countLines(run(arena, io, repo, &.{ "log", "@{upstream}..HEAD", "--pretty=%h" }));
    const stashes = countLines(run(arena, io, repo, &.{ "stash", "list" }));

    return .{
        .path = repo,
        .name = std.fs.path.basename(repo),
        .branch = branch,
        .commits = commits,
        .dirty = dirty,
        .unpushed = unpushed,
        .stashes = stashes,
    };
}

fn splitLines(arena: std.mem.Allocator, s: []const u8) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len > 0) list.append(arena, t) catch break;
    }
    return list.items;
}

fn countLines(maybe: ?[]const u8) u32 {
    const s = maybe orelse return 0;
    if (s.len == 0) return 0;
    var n: u32 = 0;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len > 0) n += 1;
    }
    return n;
}
