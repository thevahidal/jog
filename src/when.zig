//! Human-friendly date parsing for reminders. Accepts things like:
//!   today · tomorrow · mon/tue/…/sun (next occurrence) · monday …
//!   3d / +3d (in 3 days) · 2w (in 2 weeks) · 1m (in 1 month) · eow (Friday)
//!   2026-07-20 (absolute)
//! Returns a normalized "YYYY-MM-DD" string, or null if it can't be understood.

const std = @import("std");
const dt = @import("dt.zig");

const weekdays = [_][]const u8{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" };

pub fn parse(arena: std.mem.Allocator, io: std.Io, spec_in: []const u8) ?[]const u8 {
    const spec = trimLower(arena, spec_in);
    if (spec.len == 0) return null;

    const t = dt.todayDays(io);

    // Keywords.
    if (eqAny(spec, &.{ "today", "tod", "now", "tdy" })) return dt.dateFromDays(arena, t);
    if (eqAny(spec, &.{ "tomorrow", "tmr", "tom", "tomo", "tmrw" })) return dt.dateFromDays(arena, t + 1);
    if (eqAny(spec, &.{ "yesterday", "yes", "yday" })) return dt.dateFromDays(arena, t - 1);
    if (eqAny(spec, &.{ "eow", "weekend", "friday-ish" })) return dt.dateFromDays(arena, t + deltaToWeekday(t, 5)); // Friday
    if (eqAny(spec, &.{ "eom" })) return endOfMonth(arena, io);

    // Weekday names → next occurrence (0 delta means today).
    for (weekdays, 0..) |wd, idx| {
        if (std.mem.startsWith(u8, spec, wd)) {
            return dt.dateFromDays(arena, t + deltaToWeekday(t, @intCast(idx)));
        }
    }

    // Relative "<n><unit>", optionally prefixed with '+'.
    if (relative(arena, io, spec)) |s| return s;

    // Absolute YYYY-MM-DD.
    if (dt.daysFromDate(spec)) |d| return dt.dateFromDays(arena, d);

    return null;
}

/// A short relative phrase for `due` given `today` (both "YYYY-MM-DD").
/// e.g. "today", "tomorrow", "in 3 days", "2 days ago".
pub fn describe(arena: std.mem.Allocator, today_s: []const u8, due_s: []const u8) []const u8 {
    const a = dt.daysFromDate(today_s) orelse return due_s;
    const b = dt.daysFromDate(due_s) orelse return due_s;
    const delta = b - a;
    return switch (delta) {
        0 => "today",
        1 => "tomorrow",
        -1 => "yesterday",
        else => if (delta > 1)
            std.fmt.allocPrint(arena, "in {d} days", .{delta}) catch due_s
        else
            std.fmt.allocPrint(arena, "{d} days ago", .{-delta}) catch due_s,
    };
}

fn relative(arena: std.mem.Allocator, io: std.Io, spec: []const u8) ?[]const u8 {
    var s = spec;
    if (s.len > 0 and s[0] == '+') s = s[1..];
    if (s.len < 2) return null;

    // Split leading digits from the unit.
    var i: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    if (i == 0) return null;
    const n = std.fmt.parseInt(i64, s[0..i], 10) catch return null;
    const unit = s[i..];

    const t = dt.todayDays(io);
    if (eqAny(unit, &.{ "d", "day", "days" })) return dt.dateFromDays(arena, t + n);
    if (eqAny(unit, &.{ "w", "wk", "week", "weeks" })) return dt.dateFromDays(arena, t + n * 7);
    if (eqAny(unit, &.{ "m", "mo", "month", "months" })) return addMonths(arena, io, n);
    return null;
}

/// Delta in [0,6] from today's weekday to reach `target` weekday (0=Sun).
fn deltaToWeekday(today_days: i64, target: u32) i64 {
    const cur: i64 = dt.weekday(today_days);
    return @mod(@as(i64, target) - cur + 7, 7);
}

fn addMonths(arena: std.mem.Allocator, io: std.Io, n: i64) []const u8 {
    const v = dt.ymd(dt.todayDays(io) * 86400);
    var month: i64 = @as(i64, @intCast(v.m)) + n;
    var year: i64 = v.y;
    while (month > 12) {
        month -= 12;
        year += 1;
    }
    while (month < 1) {
        month += 12;
        year -= 1;
    }
    const dim = daysInMonth(year, @intCast(month));
    const day = @min(v.d, dim);
    return dt.dateFromDays(arena, dt.civilToDays(year, @intCast(month), day));
}

fn endOfMonth(arena: std.mem.Allocator, io: std.Io) []const u8 {
    const v = dt.ymd(dt.todayDays(io) * 86400);
    const dim = daysInMonth(v.y, v.m);
    return dt.dateFromDays(arena, dt.civilToDays(v.y, v.m, dim));
}

fn daysInMonth(y: i64, m: u32) u32 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if ((@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0) @as(u32, 29) else 28,
        else => 30,
    };
}

fn trimLower(arena: std.mem.Allocator, s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    const out = arena.alloc(u8, t.len) catch return t;
    for (t, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn eqAny(s: []const u8, opts: []const []const u8) bool {
    for (opts) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}
