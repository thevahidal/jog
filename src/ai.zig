//! AI via local-CLI passthrough. jog never stores keys or calls an API directly —
//! it pipes a compact context into whatever command you've configured (e.g.
//! `claude -p` or `ollama run <model>`) and streams the reply straight to your
//! terminal so it feels responsive. The whole brief is cached per work-state so
//! repeat runs are instant. Any failure degrades silently.

const std = @import("std");
const app = @import("app.zig");
const dt = @import("dt.zig");

const brief_prompt =
    \\You are a developer's terminal assistant. Below is my current work status
    \\across my git repos, todos, and integrations. Give me a SHORT brief — at most
    \\5 bullet points, most important first — telling me where I left off and what
    \\to focus on today. Be specific: name repos and PRs. Output only the bullets,
    \\no preamble, no headings.
    \\
    \\=== STATUS ===
    \\
;

/// Stream an AI brief of `context` to stdout; returns the captured text (so the
/// caller can cache it), or null when disabled/unavailable/failed.
pub fn summarizeStream(ctx: *app.Context, context: []const u8) ?[]const u8 {
    const command = ctx.cfg.getOr("ai_command", "");
    if (command.len == 0) return null;
    const prompt = std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ brief_prompt, context }) catch return null;
    return streamCommand(ctx, command, prompt);
}

/// Answer a free-form question about the user's current work, streamed to stdout.
pub fn ask(ctx: *app.Context, context: []const u8, question: []const u8) ?[]const u8 {
    const command = ctx.cfg.getOr("ai_command", "");
    if (command.len == 0) return null;
    const prompt = std.fmt.allocPrint(ctx.arena,
        \\You are my developer assistant. Here is my current work status across repos:
        \\
        \\{s}
        \\
        \\Question: {s}
        \\
        \\Answer concisely and concretely. Reference specific repos, PRs, or todos
        \\where relevant. If the status doesn't contain the answer, say so briefly.
    , .{ context, question }) catch return null;
    return streamCommand(ctx, command, prompt);
}

pub fn available(ctx: *app.Context) bool {
    return ctx.cfg.getOr("ai_command", "").len > 0;
}

/// Stream any prompt to the AI, live to the terminal. Returns captured text.
pub fn stream(ctx: *app.Context, prompt: []const u8) ?[]const u8 {
    const command = ctx.cfg.getOr("ai_command", "");
    if (command.len == 0) return null;
    return streamCommand(ctx, command, prompt);
}

/// Run a prompt through the AI and capture the reply *without* streaming it —
/// for when we need to parse the output (plugin code, structured JSON).
pub fn complete(ctx: *app.Context, prompt: []const u8) ?[]const u8 {
    const command = ctx.cfg.getOr("ai_command", "");
    if (command.len == 0) return null;

    const ptmp = std.fs.path.join(ctx.arena, &.{ ctx.paths.dir, ".ai_prompt" }) catch return null;
    std.Io.Dir.cwd().createDirPath(ctx.io, ctx.paths.dir) catch return null;
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = ptmp, .data = prompt }) catch return null;

    const full = std.fmt.allocPrint(ctx.arena, "cat '{s}' | {s}", .{ ptmp, command }) catch return null;
    const res = std.process.run(ctx.arena, ctx.io, .{ .argv = &.{ "sh", "-c", full } }) catch return null;
    switch (res.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const out = std.mem.trim(u8, res.stdout, " \t\r\n");
    return if (out.len == 0) null else out;
}

/// Generate a plugin script from a natural-language description. Returns the
/// script (markdown fences stripped), or null if AI is unavailable/failed.
pub fn generatePlugin(ctx: *app.Context, name: []const u8, desc: []const u8) ?[]const u8 {
    const prompt = std.fmt.allocPrint(ctx.arena,
        \\Write a POSIX /bin/sh script for a "jog" plugin named "{s}".
        \\Purpose: {s}
        \\
        \\Requirements:
        \\- Print a JSON array to stdout — items with fields: kind, title, url,
        \\  status, note (only "title" is required).
        \\- You may use curl and jq. Read any secrets/URLs from environment
        \\  variables and document them in a comment header (do NOT hardcode them).
        \\- Env already provided: JOG_REPOS (newline-separated paths),
        \\  JOG_SINCE_DAYS, JOG_TODAY.
        \\- Always exit 0 and print at least [] on any error or missing config.
        \\
        \\Output ONLY the raw script. No markdown fences, no explanation.
    , .{ name, desc }) catch return null;

    const out = complete(ctx, prompt) orelse return null;
    return stripFences(out);
}

/// Remove ``` fences the model may wrap code in.
fn stripFences(s: []const u8) []const u8 {
    var t = std.mem.trim(u8, s, " \t\r\n");
    if (std.mem.startsWith(u8, t, "```")) {
        // drop the opening fence line
        if (std.mem.indexOfScalar(u8, t, '\n')) |nl| t = t[nl + 1 ..];
        // drop a trailing fence
        if (std.mem.lastIndexOf(u8, t, "```")) |close| t = t[0..close];
    }
    return std.mem.trim(u8, t, " \t\r\n");
}

/// Run `command` with `prompt` on stdin, streaming its stdout live to the
/// terminal while also capturing it (via `tee`) for the return value/cache.
fn streamCommand(ctx: *app.Context, command: []const u8, prompt: []const u8) ?[]const u8 {
    const ptmp = std.fs.path.join(ctx.arena, &.{ ctx.paths.dir, ".ai_prompt" }) catch return null;
    const otmp = std.fs.path.join(ctx.arena, &.{ ctx.paths.dir, ".ai_out" }) catch return null;
    std.Io.Dir.cwd().createDirPath(ctx.io, ctx.paths.dir) catch return null;
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = ptmp, .data = prompt }) catch return null;

    const full = std.fmt.allocPrint(ctx.arena, "cat '{s}' | {s} | tee '{s}'", .{ ptmp, command, otmp }) catch return null;

    // stdout/stderr inherit → the model's tokens (and its own progress) stream
    // straight to the user; tee mirrors stdout into otmp for capture.
    var child = std.process.spawn(ctx.io, .{
        .argv = &.{ "sh", "-c", full },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return null;
    const term = child.wait(ctx.io) catch return null;
    switch (term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    const out = std.Io.Dir.cwd().readFileAlloc(ctx.io, otmp, ctx.arena, .unlimited) catch return null;
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

/// Whole-brief cache with a TTL, so quick repeat runs skip data gathering and
/// the AI call entirely. Returns the cached brief text if younger than `ttl_secs`.
pub fn briefCacheGet(ctx: *app.Context, key: []const u8, ttl_secs: u32) ?[]const u8 {
    if (ttl_secs == 0) return null;
    const path = briefCachePath(ctx) orelse return null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .unlimited) catch return null;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const ts_line = lines.next() orelse return null;
    const key_line = lines.next() orelse return null;
    const ts = std.fmt.parseInt(i64, std.mem.trim(u8, ts_line, " \t\r"), 10) catch return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, key_line, " \t\r"), key)) return null;
    if (dt.nowEpoch(ctx.io) - ts > ttl_secs) return null;

    const rest_start = ts_line.len + 1 + key_line.len + 1;
    if (rest_start >= bytes.len) return null;
    return bytes[rest_start..];
}

pub fn briefCachePut(ctx: *app.Context, key: []const u8, text: []const u8) void {
    const path = briefCachePath(ctx) orelse return;
    const data = std.fmt.allocPrint(ctx.arena, "{d}\n{s}\n{s}", .{ dt.nowEpoch(ctx.io), key, text }) catch return;
    std.Io.Dir.cwd().createDirPath(ctx.io, ctx.paths.dir) catch return;
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = data }) catch return;
}

/// Invalidate the cached brief so the next run rebuilds (e.g. after a dismiss).
pub fn clearBriefCache(ctx: *app.Context) void {
    const path = briefCachePath(ctx) orelse return;
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = "0\n" }) catch {};
}

fn briefCachePath(ctx: *app.Context) ?[]const u8 {
    return std.fs.path.join(ctx.arena, &.{ ctx.paths.dir, "brief_cache" }) catch null;
}
