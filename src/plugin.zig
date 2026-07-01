//! Generic plugin host. A plugin is any command that prints the jog JSON
//! contract on stdout. The core knows nothing about what a plugin integrates;
//! it just runs the command, passes context via env, and parses the items.

const std = @import("std");

pub const Item = struct {
    kind: []const u8 = "",
    title: []const u8 = "",
    url: []const u8 = "",
    status: []const u8 = "",
    updated: []const u8 = "",
    note: []const u8 = "",
};

pub const Result = struct {
    items: []const Item,
    err: ?[]const u8, // human-readable reason when the plugin couldn't run
};

/// JSON shape accepted from a plugin (all fields optional).
const ItemJson = struct {
    kind: ?[]const u8 = null,
    title: ?[]const u8 = null,
    url: ?[]const u8 = null,
    status: ?[]const u8 = null,
    updated: ?[]const u8 = null,
    note: ?[]const u8 = null,
};

pub const Env = struct {
    repos: []const []const u8,
    days: u32,
    today: []const u8,
};

/// Run `command` via `sh -c` (so pipes/quoting work), passing context through
/// JOG_* env vars, and parse its stdout as the JSON contract. Never throws for
/// plugin-side problems — those come back in `Result.err`.
pub fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    parent_env: *std.process.Environ.Map,
    command: []const u8,
    env: Env,
    env_file: ?[]const u8,
) Result {
    const child_env = buildEnv(arena, io, parent_env, env, env_file) catch null;

    const res = std.process.run(arena, io, .{
        .argv = &.{ "sh", "-c", command },
        .environ_map = if (child_env) |*m| m else null,
    }) catch |e| {
        return .{ .items = &.{}, .err = std.fmt.allocPrint(arena, "could not run: {s}", .{@errorName(e)}) catch "could not run" };
    };

    switch (res.term) {
        .exited => |code| if (code != 0) {
            const reason = std.mem.trim(u8, res.stderr, " \t\r\n");
            return .{ .items = &.{}, .err = if (reason.len > 0)
                std.fmt.allocPrint(arena, "exit {d}: {s}", .{ code, firstLine(reason) }) catch "non-zero exit"
            else
                std.fmt.allocPrint(arena, "exit {d}", .{code}) catch "non-zero exit" };
        },
        else => return .{ .items = &.{}, .err = "terminated abnormally" },
    }

    const stdout = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (stdout.len == 0) return .{ .items = &.{}, .err = null };

    const raw = std.json.parseFromSliceLeaky([]ItemJson, arena, stdout, .{ .ignore_unknown_fields = true }) catch {
        return .{ .items = &.{}, .err = "invalid JSON from plugin" };
    };

    var items: std.ArrayList(Item) = .empty;
    for (raw) |r| {
        items.append(arena, .{
            .kind = r.kind orelse "",
            .title = r.title orelse "",
            .url = r.url orelse "",
            .status = r.status orelse "",
            .updated = r.updated orelse "",
            .note = r.note orelse "",
        }) catch break;
    }
    return .{ .items = items.items, .err = null };
}

fn buildEnv(arena: std.mem.Allocator, io: std.Io, parent: *std.process.Environ.Map, env: Env, env_file: ?[]const u8) !std.process.Environ.Map {
    var m = try parent.clone(arena);

    // Personal config/secrets from ~/.config/jog/env (KEY=VALUE lines).
    if (env_file) |path| {
        if (std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited)) |bytes| {
            var lines = std.mem.splitScalar(u8, bytes, '\n');
            while (lines.next()) |line| {
                const t = std.mem.trim(u8, line, " \t\r");
                if (t.len == 0 or t[0] == '#') continue;
                const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
                const key = std.mem.trim(u8, t[0..eq], " \t");
                var val = std.mem.trim(u8, t[eq + 1 ..], " \t");
                // Strip optional surrounding quotes.
                if (val.len >= 2 and (val[0] == '"' or val[0] == '\'') and val[val.len - 1] == val[0])
                    val = val[1 .. val.len - 1];
                if (key.len > 0) try m.put(key, val);
            }
        } else |_| {}
    }

    var repos_buf: std.ArrayList(u8) = .empty;
    for (env.repos, 0..) |r, i| {
        if (i != 0) try repos_buf.append(arena, '\n');
        try repos_buf.appendSlice(arena, r);
    }
    try m.put("JOG_REPOS", repos_buf.items);
    try m.put("JOG_SINCE_DAYS", try std.fmt.allocPrint(arena, "{d}", .{env.days}));
    try m.put("JOG_TODAY", env.today);
    return m;
}

fn firstLine(s: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, s, '\n') orelse return s;
    return s[0..nl];
}
