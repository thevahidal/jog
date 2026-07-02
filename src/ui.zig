//! Terminal styling. A Theme holds ANSI codes that collapse to "" when color is
//! off (piped output, NO_COLOR, dumb terminal) so the same render code produces
//! either a beautiful colored view or clean plain text.

const std = @import("std");

pub const Theme = struct {
    reset: []const u8 = "",
    bold: []const u8 = "",
    dim: []const u8 = "",
    italic: []const u8 = "",
    red: []const u8 = "",
    green: []const u8 = "",
    yellow: []const u8 = "",
    blue: []const u8 = "",
    magenta: []const u8 = "",
    cyan: []const u8 = "",
    gray: []const u8 = "",
    accent: []const u8 = "", // brand blue
    accent_bold: []const u8 = "",

    pub fn init(on: bool) Theme {
        if (!on) return .{};
        return .{
            .reset = "\x1b[0m",
            .bold = "\x1b[1m",
            .dim = "\x1b[2m",
            .italic = "\x1b[3m",
            .red = "\x1b[38;5;203m",
            .green = "\x1b[38;5;114m",
            .yellow = "\x1b[38;5;221m",
            .blue = "\x1b[38;5;75m",
            .magenta = "\x1b[38;5;176m",
            .cyan = "\x1b[38;5;80m",
            .gray = "\x1b[38;5;244m",
            .accent = "\x1b[38;5;39m",
            .accent_bold = "\x1b[1;38;5;39m",
        };
    }
};

/// Decide whether to emit color: honor NO_COLOR / CLICOLOR_FORCE, else require a tty.
pub fn colorEnabled(io: std.Io, env: *std.process.Environ.Map) bool {
    if (env.get("NO_COLOR")) |_| return false;
    if (env.get("CLICOLOR_FORCE")) |v| {
        if (v.len > 0 and !std.mem.eql(u8, v, "0")) return true;
    }
    if (env.get("TERM")) |t| {
        if (std.mem.eql(u8, t, "dumb")) return false;
    }
    return std.Io.File.stdout().isTty(io) catch false;
}
