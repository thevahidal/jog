//! Todos stored as a tab-separated file:
//!   id \t status \t created \t repo \t text \t due
//! (repo empty = global; due empty = no reminder date). The `due` column is
//! optional so older files load unchanged. The file is rewritten on mutation.

const std = @import("std");
const dt = @import("dt.zig");

pub const Todo = struct {
    id: u32,
    done: bool,
    created: []const u8, // YYYY-MM-DD
    repo: []const u8, // "" = global
    text: []const u8,
    due: []const u8 = "", // YYYY-MM-DD, or "" for no reminder date
};

pub fn load(arena: std.mem.Allocator, io: std.Io, path: []const u8) []Todo {
    var list: std.ArrayList(Todo) = .empty;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch return list.items;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var it = std.mem.splitScalar(u8, line, '\t');
        const id_s = it.next() orelse continue;
        const status = it.next() orelse continue;
        const created = it.next() orelse continue;
        const repo = it.next() orelse continue;
        const text = it.next() orelse continue;
        const due = it.next() orelse ""; // optional 6th column
        const id = std.fmt.parseInt(u32, id_s, 10) catch continue;
        list.append(arena, .{
            .id = id,
            .done = std.mem.eql(u8, status, "done"),
            .created = created,
            .repo = repo,
            .text = text,
            .due = due,
        }) catch break;
    }
    return list.items;
}

fn save(arena: std.mem.Allocator, io: std.Io, dir: []const u8, path: []const u8, todos: []const Todo) !void {
    var b: std.ArrayList(u8) = .empty;
    for (todos) |t| {
        const line = try std.fmt.allocPrint(arena, "{d}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{
            t.id,
            if (t.done) "done" else "open",
            t.created,
            t.repo,
            t.text,
            t.due,
        });
        try b.appendSlice(arena, line);
    }
    try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = b.items });
}

/// Add a todo; returns its new id. `repo` "" means global; `due` "" means none.
pub fn add(arena: std.mem.Allocator, io: std.Io, dir: []const u8, path: []const u8, repo: []const u8, text: []const u8, due: []const u8) !u32 {
    var todos: std.ArrayList(Todo) = .empty;
    try todos.appendSlice(arena, load(arena, io, path));

    var max_id: u32 = 0;
    for (todos.items) |t| max_id = @max(max_id, t.id);
    const id = max_id + 1;

    try todos.append(arena, .{
        .id = id,
        .done = false,
        .created = dt.today(arena, io),
        .repo = sanitize(arena, repo),
        .text = sanitize(arena, text),
        .due = due,
    });
    try save(arena, io, dir, path, todos.items);
    return id;
}

/// Set (or clear, with "") a todo's due date. Returns whether it was found.
pub fn setDue(arena: std.mem.Allocator, io: std.Io, dir: []const u8, path: []const u8, id: u32, due: []const u8) !bool {
    const todos = load(arena, io, path);
    var found = false;
    for (todos) |*t| {
        if (t.id == id) {
            t.due = due;
            t.done = false; // re-open when (re)scheduling
            found = true;
        }
    }
    if (found) try save(arena, io, dir, path, todos);
    return found;
}

pub fn setDone(arena: std.mem.Allocator, io: std.Io, dir: []const u8, path: []const u8, id: u32) !bool {
    const todos = load(arena, io, path);
    var found = false;
    for (todos) |*t| {
        if (t.id == id) {
            t.done = true;
            found = true;
        }
    }
    if (found) try save(arena, io, dir, path, todos);
    return found;
}

pub fn remove(arena: std.mem.Allocator, io: std.Io, dir: []const u8, path: []const u8, id: u32) !bool {
    const todos = load(arena, io, path);
    var kept: std.ArrayList(Todo) = .empty;
    var found = false;
    for (todos) |t| {
        if (t.id == id) {
            found = true;
        } else {
            try kept.append(arena, t);
        }
    }
    if (found) try save(arena, io, dir, path, kept.items);
    return found;
}

/// Replace tabs/newlines with spaces so a value stays on one TSV field.
fn sanitize(arena: std.mem.Allocator, s: []const u8) []const u8 {
    const out = arena.alloc(u8, s.len) catch return s;
    for (s, 0..) |c, i| out[i] = if (c == '\t' or c == '\n' or c == '\r') ' ' else c;
    return out;
}
