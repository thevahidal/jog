//! Resolves jog's config/state locations (XDG-aware).

const std = @import("std");

pub const Paths = struct {
    /// Base config dir, e.g. ~/.config/jog
    dir: []const u8,
    /// Full path to the config file (dir/config)
    config_file: []const u8,
    /// Full path to todos.tsv
    todos_file: []const u8,
    /// Full path to seen.tsv
    seen_file: []const u8,
    /// Directory where bundled/installed plugins live (dir/plugins)
    plugins_dir: []const u8,
    /// Personal env file (dir/env) injected into plugin processes — for URLs,
    /// tokens, and other per-user values that must not live in the repo.
    env_file: []const u8,
};

/// Resolve all paths from the environment. Uses $XDG_CONFIG_HOME, else $HOME/.config.
pub fn resolve(arena: std.mem.Allocator, env: *std.process.Environ.Map) !Paths {
    const base = blk: {
        if (env.get("XDG_CONFIG_HOME")) |xdg| {
            if (xdg.len > 0) break :blk try std.fs.path.join(arena, &.{ xdg, "jog" });
        }
        const home = env.get("HOME") orelse return error.NoHomeDir;
        break :blk try std.fs.path.join(arena, &.{ home, ".config", "jog" });
    };
    return .{
        .dir = base,
        .config_file = try std.fs.path.join(arena, &.{ base, "config" }),
        .todos_file = try std.fs.path.join(arena, &.{ base, "todos.tsv" }),
        .seen_file = try std.fs.path.join(arena, &.{ base, "seen.tsv" }),
        .plugins_dir = try std.fs.path.join(arena, &.{ base, "plugins" }),
        .env_file = try std.fs.path.join(arena, &.{ base, "env" }),
    };
}
