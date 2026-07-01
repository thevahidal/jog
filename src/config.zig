//! Config is a flat `key = value` store with typed getters and built-in defaults,
//! so jog works with no config file at all (zero-config). Arbitrary keys like
//! `plugin.<name>` and per-section knobs are supported without schema changes.

const std = @import("std");

pub const Plugin = struct {
    name: []const u8,
    command: []const u8,
};

pub const Config = struct {
    arena: std.mem.Allocator,
    entries: std.ArrayList(Entry),
    /// Whether a config file was actually present on disk.
    loaded_from_file: bool,

    pub const Entry = struct { key: []const u8, value: []const u8 };

    pub fn get(self: Config, key: []const u8) ?[]const u8 {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }

    pub fn getOr(self: Config, key: []const u8, default: []const u8) []const u8 {
        return self.get(key) orelse default;
    }

    pub fn getBool(self: Config, key: []const u8, default: bool) bool {
        const v = self.get(key) orelse return default;
        return std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "yes");
    }

    pub fn getInt(self: Config, key: []const u8, default: u32) u32 {
        const v = self.get(key) orelse return default;
        return std.fmt.parseInt(u32, v, 10) catch default;
    }

    /// Comma-separated value split into trimmed items, or null if key absent.
    pub fn getList(self: Config, key: []const u8) ?[][]const u8 {
        const v = self.get(key) orelse return null;
        return splitCsv(self.arena, v) catch null;
    }

    /// All `plugin.<name> = command` entries.
    pub fn plugins(self: Config) []Plugin {
        var list: std.ArrayList(Plugin) = .empty;
        for (self.entries.items) |e| {
            if (std.mem.startsWith(u8, e.key, "plugin.")) {
                list.append(self.arena, .{
                    .name = e.key["plugin.".len..],
                    .command = e.value,
                }) catch continue;
            }
        }
        return list.items;
    }

    /// Discovery roots, defaulting to $HOME/dev when unset.
    pub fn roots(self: Config, env: *std.process.Environ.Map) [][]const u8 {
        if (self.getList("roots")) |r| return r;
        const home = env.get("HOME") orelse return &.{};
        const dev = std.fs.path.join(self.arena, &.{ home, "dev" }) catch return &.{};
        const one = self.arena.alloc([]const u8, 1) catch return &.{};
        one[0] = dev;
        return one;
    }
};

fn splitCsv(arena: std.mem.Allocator, v: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, v, ',');
    while (it.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t");
        if (item.len > 0) try list.append(arena, item);
    }
    return list.items;
}

/// Load config from disk. If the file is absent, returns an empty config whose
/// getters supply defaults (zero-config). `arena` owns all returned memory.
pub fn load(arena: std.mem.Allocator, io: std.Io, config_file: []const u8) !Config {
    var entries: std.ArrayList(Config.Entry) = .empty;

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, config_file, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return .{ .arena = arena, .entries = entries, .loaded_from_file = false },
        else => return err,
    };

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        const value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
        if (key.len == 0) continue;
        try entries.append(arena, .{ .key = key, .value = value });
    }

    return .{ .arena = arena, .entries = entries, .loaded_from_file = true };
}

pub const default_file =
    \\# jog config — every line is optional; defaults are shown commented out.
    \\# Edit to taste, then run `jog` to see the effect.
    \\
    \\# Where to look for git repos (comma-separated):
    \\# roots = ~/dev
    \\# How deep to search under each root:
    \\# depth = 3
    \\# Lookback window (days) for "recent" activity:
    \\# days = 7
    \\
    \\# By default jog summarizes the briefing with AI into a short brief, and
    \\# falls back to the full breakdown if the AI command is missing or fails.
    \\# The command receives the briefing as a prompt on stdin (no keys in jog).
    \\# ai_enabled = true          # set false to always show the full briefing
    \\# ai_command = claude -p     # any CLI that reads a prompt on stdin
    \\# cache_ttl = 900            # reuse a brief for N seconds (0 = always rebuild)
    \\
    \\# Show gentle one-line hints at the end of the briefing:
    \\# hints = true
    \\
    \\# Which sections show, and in what order (omit one to hide it).
    \\# Built-ins: todos, git. Plus any registered plugin name.
    \\# sections = todos, git, standup, loose-ends, github, code-todos
    \\
    \\# Per-section knobs:
    \\# git.show = branch, commits, dirty, unpushed, stash
    \\# git.max_commits = 5
    \\# todos.max = 10
    \\
    \\# Register plugins (any executable that prints the jog JSON contract):
    \\# plugin.github = ~/.config/jog/plugins/jog-github
    \\# plugin.jira = ~/.config/jog/plugins/jog-jira.sh
    \\
;

/// Write the commented default config to disk, creating the config dir.
pub fn writeDefault(io: std.Io, dir: []const u8, config_file: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config_file, .data = default_file });
}

/// Set `key = value` in the config file, preserving comments and other lines.
/// Replaces an existing uncommented entry, or appends one. Seeds the commented
/// default template when no file exists yet.
pub fn setKey(arena: std.mem.Allocator, io: std.Io, dir: []const u8, config_file: []const u8, key: []const u8, value: []const u8) !void {
    const existing = std.Io.Dir.cwd().readFileAlloc(io, config_file, arena, .unlimited) catch default_file;

    var out: std.ArrayList(u8) = .empty;
    var replaced = false;
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        if (lineKey(line)) |k| {
            if (std.mem.eql(u8, k, key)) {
                try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{s} = {s}\n", .{ key, value }));
                replaced = true;
                continue;
            }
        }
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    if (!replaced) {
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{s} = {s}\n", .{ key, value }));
    }

    try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config_file, .data = out.items });
}

/// Remove an uncommented `key = …` line from the config file. Returns whether
/// anything was removed.
pub fn removeKey(arena: std.mem.Allocator, io: std.Io, dir: []const u8, config_file: []const u8, key: []const u8) !bool {
    const existing = std.Io.Dir.cwd().readFileAlloc(io, config_file, arena, .unlimited) catch return false;

    var out: std.ArrayList(u8) = .empty;
    var removed = false;
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        if (lineKey(line)) |k| {
            if (std.mem.eql(u8, k, key)) {
                removed = true;
                continue;
            }
        }
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    if (removed) {
        try std.Io.Dir.cwd().createDirPath(io, dir);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config_file, .data = out.items });
    }
    return removed;
}

/// If `line` is an uncommented `key = value`, return the trimmed key.
fn lineKey(line: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0 or t[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, t, '=') orelse return null;
    const k = std.mem.trim(u8, t[0..eq], " \t");
    if (k.len == 0) return null;
    return k;
}
