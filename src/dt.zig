//! Minimal date helpers (UTC). Used for todo timestamps and the once-per-day gate.

const std = @import("std");

pub const Ymd = struct { y: i64, m: u32, d: u32 };

pub fn nowEpoch(io: std.Io) i64 {
    return std.Io.Clock.now(.real, io).toSeconds();
}

/// Convert epoch seconds to a UTC calendar date (Howard Hinnant's algorithm).
pub fn ymd(epoch_secs: i64) Ymd {
    const days = @divFloor(epoch_secs, 86400);
    var z = days + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365); // [0, 399]
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365]
    const mp = @divFloor(5 * doy + 2, 153); // [0, 11]
    const d: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1); // [1, 31]
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9); // [1, 12]
    _ = &z;
    return .{ .y = y + @as(i64, if (m <= 2) 1 else 0), .m = m, .d = d };
}

/// "YYYY-MM-DD" for the given epoch, arena-allocated.
pub fn dateString(arena: std.mem.Allocator, epoch_secs: i64) []const u8 {
    const v = ymd(epoch_secs);
    const year: u32 = if (v.y < 0) 0 else @intCast(v.y);
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, v.m, v.d }) catch "0000-00-00";
}

/// Today's date as "YYYY-MM-DD".
pub fn today(arena: std.mem.Allocator, io: std.Io) []const u8 {
    return dateString(arena, nowEpoch(io));
}

/// Number of whole days since the Unix epoch (UTC).
pub fn todayDays(io: std.Io) i64 {
    return @divFloor(nowEpoch(io), 86400);
}

/// Days since epoch for a calendar date (Howard Hinnant's days_from_civil).
pub fn civilToDays(y: i64, m: u32, d: u32) i64 {
    var yy = y;
    if (m <= 2) yy -= 1;
    const era = @divFloor(if (yy >= 0) yy else yy - 399, 400);
    const yoe = yy - era * 400; // [0, 399]
    const mm: i64 = @intCast(m);
    const doy = @divFloor(153 * (mm + (if (m > 2) @as(i64, -3) else 9)) + 2, 5) + @as(i64, @intCast(d)) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

/// "YYYY-MM-DD" for a days-since-epoch count.
pub fn dateFromDays(arena: std.mem.Allocator, days: i64) []const u8 {
    return dateString(arena, days * 86400);
}

/// Parse "YYYY-MM-DD" into days since epoch, or null if malformed.
pub fn daysFromDate(s: []const u8) ?i64 {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const m = std.fmt.parseInt(u32, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u32, s[8..10], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > 31) return null;
    return civilToDays(y, m, d);
}

/// Day of week for a days-since-epoch count. 0=Sunday … 6=Saturday.
pub fn weekday(days: i64) u32 {
    return @intCast(@mod(days + 4, 7));
}

const weekday_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// A friendly date like "Wednesday, Jul 2".
pub fn pretty(arena: std.mem.Allocator, io: std.Io) []const u8 {
    const days = todayDays(io);
    const v = ymd(days * 86400);
    const wd = weekday_names[weekday(days)];
    const mo = if (v.m >= 1 and v.m <= 12) month_names[v.m - 1] else "?";
    return std.fmt.allocPrint(arena, "{s}, {s} {d}", .{ wd, mo, v.d }) catch wd;
}

/// A time-of-day greeting (UTC-based, so approximate near midnight).
pub fn greeting(io: std.Io) []const u8 {
    const hour = @mod(@divFloor(nowEpoch(io), 3600), 24);
    if (hour < 12) return "good morning";
    if (hour < 18) return "good afternoon";
    return "good evening";
}
