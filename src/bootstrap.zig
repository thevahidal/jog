//! First-run bootstrap: writes the bundled plugin scripts into the user's config
//! and auto-registers the ones whose dependency is present. The scripts are
//! embedded at compile time so the installed binary is self-contained. The core
//! still treats these as ordinary plugins — nothing here is special-cased at run
//! time beyond installation.

const std = @import("std");
const app = @import("app.zig");
const config_mod = @import("config.zig");

const Dep = enum { git, github, jira, odoo, gitlab, linear, calendar, docker, pagerduty };

const Bundled = struct {
    name: []const u8,
    file: []const u8,
    body: []const u8,
    dep: Dep,
};

const bundled = [_]Bundled{
    .{ .name = "standup", .file = "jog-standup", .body = @embedFile("jog-standup"), .dep = .git },
    .{ .name = "loose-ends", .file = "jog-loose-ends", .body = @embedFile("jog-loose-ends"), .dep = .git },
    .{ .name = "code-todos", .file = "jog-code-todos", .body = @embedFile("jog-code-todos"), .dep = .git },
    .{ .name = "github", .file = "jog-github", .body = @embedFile("jog-github"), .dep = .github },
    .{ .name = "jira", .file = "jog-jira", .body = @embedFile("jog-jira"), .dep = .jira },
    .{ .name = "odoo", .file = "jog-odoo", .body = @embedFile("jog-odoo"), .dep = .odoo },
    .{ .name = "gitlab", .file = "jog-gitlab", .body = @embedFile("jog-gitlab"), .dep = .gitlab },
    .{ .name = "linear", .file = "jog-linear", .body = @embedFile("jog-linear"), .dep = .linear },
    .{ .name = "calendar", .file = "jog-calendar", .body = @embedFile("jog-calendar"), .dep = .calendar },
    .{ .name = "docker", .file = "jog-docker", .body = @embedFile("jog-docker"), .dep = .docker },
    .{ .name = "pagerduty", .file = "jog-pagerduty", .body = @embedFile("jog-pagerduty"), .dep = .pagerduty },
};

/// Template for the personal env file, holding per-user URLs and secrets that
/// must never live in the repo. Plugins read these at run time.
const env_example =
    \\# jog personal env — per-user URLs, accounts and secrets (NOT in the repo).
    \\# Copy needed lines into ~/.config/jog/env and fill them in. chmod 600 it.
    \\# jog injects these into plugin processes.
    \\
    \\# Jira (jog-jira):
    \\# JIRA_URL=https://your-org.atlassian.net
    \\# JIRA_EMAIL=you@example.com
    \\# JIRA_TOKEN=your-api-token        # https://id.atlassian.com/manage/api-tokens
    \\
    \\# Odoo (jog-odoo):
    \\# ODOO_URL=https://erp.example.com
    \\# ODOO_DB=your-database
    \\# ODOO_USER=you@example.com
    \\# ODOO_PASSWORD=your-password-or-api-key
    \\
    \\# GitLab (jog-gitlab):
    \\# GITLAB_TOKEN=your-personal-access-token   # scope: read_api
    \\# GITLAB_URL=https://gitlab.com             # only for self-hosted
    \\
    \\# Linear (jog-linear):
    \\# LINEAR_API_KEY=your-personal-api-key      # Settings → Security & access
    \\
    \\# Calendar (jog-calendar) — a private iCalendar (.ics) URL:
    \\# JOG_CALENDAR_URL=https://calendar.google.com/…/basic.ics
    \\
    \\# PagerDuty (jog-pagerduty):
    \\# PAGERDUTY_TOKEN=your-rest-api-key
    \\# PAGERDUTY_USER_ID=your-user-id            # optional — filter to you
    \\
    \\# (jog-docker needs no config — it shows running containers when Docker is up)
    \\
;

pub const Report = struct {
    installed: u32 = 0,
    registered: std.ArrayList([]const u8),
    skipped: std.ArrayList([]const u8),
    ai_command: ?[]const u8 = null,
};

/// Install bundled scripts and register the available ones. Best-effort: any
/// individual failure is skipped rather than fatal.
pub fn install(ctx: *app.Context) Report {
    var report: Report = .{ .registered = .empty, .skipped = .empty };

    std.Io.Dir.cwd().createDirPath(ctx.io, ctx.paths.plugins_dir) catch {};

    // Refresh the env template (env.example is a template; the real `env` file is
    // never touched). Always rewrite so it lists the current integrations.
    if (std.fs.path.join(ctx.arena, &.{ ctx.paths.dir, "env.example" })) |example| {
        std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = example, .data = env_example }) catch {};
    } else |_| {}

    // Pick a working AI command if the user hasn't set one, so the AI brief works
    // out of the box. Prefer claude (if functional), else ollama with a model.
    if (ctx.cfg.get("ai_command") == null) {
        if (detectAi(ctx)) |cmd| {
            config_mod.setKey(ctx.arena, ctx.io, ctx.paths.dir, ctx.paths.config_file, "ai_command", cmd) catch {};
            report.ai_command = cmd;
        }
    }

    const git_ok = hasCommand(ctx, "git");
    const web_ok = hasCommand(ctx, "curl") and hasCommand(ctx, "jq");
    const github_ok = hasCommand(ctx, "gh") and hasCommand(ctx, "jq") and ghAuthed(ctx);
    const jira_ok = web_ok and envHas(ctx, "JIRA_URL") and envHas(ctx, "JIRA_TOKEN");
    const odoo_ok = web_ok and envHas(ctx, "ODOO_URL") and envHas(ctx, "ODOO_PASSWORD");
    const gitlab_ok = web_ok and envHas(ctx, "GITLAB_TOKEN");
    const linear_ok = web_ok and envHas(ctx, "LINEAR_API_KEY");
    const calendar_ok = web_ok and (envHas(ctx, "JOG_CALENDAR_URL") or envHas(ctx, "CALENDAR_URL"));
    const docker_ok = hasCommand(ctx, "docker") and hasCommand(ctx, "jq");
    const pagerduty_ok = web_ok and envHas(ctx, "PAGERDUTY_TOKEN");

    for (bundled) |p| {
        const dest = std.fs.path.join(ctx.arena, &.{ ctx.paths.plugins_dir, p.file }) catch continue;
        std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = dest, .data = p.body }) catch continue;
        report.installed += 1;

        const available = switch (p.dep) {
            .git => git_ok,
            .github => github_ok,
            .jira => jira_ok,
            .odoo => odoo_ok,
            .gitlab => gitlab_ok,
            .linear => linear_ok,
            .calendar => calendar_ok,
            .docker => docker_ok,
            .pagerduty => pagerduty_ok,
        };
        if (!available) {
            report.skipped.append(ctx.arena, p.name) catch {};
            continue;
        }

        const key = std.fmt.allocPrint(ctx.arena, "plugin.{s}", .{p.name}) catch continue;
        const cmd = std.fmt.allocPrint(ctx.arena, "sh '{s}'", .{dest}) catch continue;
        config_mod.setKey(ctx.arena, ctx.io, ctx.paths.dir, ctx.paths.config_file, key, cmd) catch continue;
        report.registered.append(ctx.arena, p.name) catch {};
    }

    return report;
}

/// Choose a working AI command, or null if none is usable. Tries cloud CLIs that
/// read a prompt on stdin (claude, then gemini), then a local ollama model.
/// (codex works too but its agentic output is noisy — set it manually if wanted.)
fn detectAi(ctx: *app.Context) ?[]const u8 {
    if (hasCommand(ctx, "claude") and aiWorks(ctx, "claude -p")) return "claude -p";
    if (hasCommand(ctx, "gemini") and aiWorks(ctx, "gemini -p \"\"")) return "gemini -p \"\"";
    if (hasCommand(ctx, "ollama")) {
        if (firstOllamaModel(ctx)) |model| {
            return std.fmt.allocPrint(ctx.arena, "ollama run {s}", .{model}) catch null;
        }
    }
    return null;
}

/// Test an AI command with a trivial prompt; reject empty output or auth errors.
fn aiWorks(ctx: *app.Context, command: []const u8) bool {
    const full = std.fmt.allocPrint(ctx.arena, "printf 'reply with: ok' | {s}", .{command}) catch return false;
    const out = shOut(ctx, full) orelse return false;
    if (std.mem.indexOf(u8, out, "authenticat") != null) return false;
    if (std.mem.indexOf(u8, out, "API Error") != null) return false;
    return out.len > 0;
}

fn firstOllamaModel(ctx: *app.Context) ?[]const u8 {
    const out = shOut(ctx, "ollama list 2>/dev/null | awk 'NR==2{print $1}'") orelse return null;
    const m = std.mem.trim(u8, out, " \t\r\n");
    return if (m.len > 0) m else null;
}

fn hasCommand(ctx: *app.Context, name: []const u8) bool {
    const cmd = std.fmt.allocPrint(ctx.arena, "command -v {s} >/dev/null 2>&1", .{name}) catch return false;
    return shOk(ctx, cmd);
}

/// Whether `key` is set, either in the parent environment or the personal env file.
fn envHas(ctx: *app.Context, key: []const u8) bool {
    if (ctx.env.get(key)) |v| {
        if (v.len > 0) return true;
    }
    const bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, ctx.paths.env_file, ctx.arena, .unlimited) catch return false;
    const needle = std.fmt.allocPrint(ctx.arena, "{s}=", .{key}) catch return false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        if (std.mem.startsWith(u8, t, needle)) return true;
    }
    return false;
}

fn shOut(ctx: *app.Context, command: []const u8) ?[]const u8 {
    const res = std.process.run(ctx.arena, ctx.io, .{ .argv = &.{ "sh", "-c", command } }) catch return null;
    switch (res.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    return std.mem.trim(u8, res.stdout, " \t\r\n");
}

fn ghAuthed(ctx: *app.Context) bool {
    return shOk(ctx, "gh auth status >/dev/null 2>&1");
}

fn shOk(ctx: *app.Context, command: []const u8) bool {
    const res = std.process.run(ctx.arena, ctx.io, .{ .argv = &.{ "sh", "-c", command } }) catch return false;
    return switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
}
