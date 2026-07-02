//! Composes the briefing from an ordered list of sections. A section is a
//! built-in source (git, todos) or a registered plugin. The order and which
//! sections appear come from the `sections` config key.
//!
//! Each render builds two things in a single pass: the rich human view, and a
//! compact plain-text context for the AI summarizer (so plugins run only once
//! and the model sees focused facts rather than the whole formatted wall).

const std = @import("std");
const app = @import("app.zig");
const discover_mod = @import("discover.zig");
const git = @import("git.zig");
const todo = @import("todo.zig");
const plugin = @import("plugin.zig");
const dt = @import("dt.zig");
const dismiss = @import("dismiss.zig");
const when = @import("when.zig");

const Context = app.Context;
const Buf = app.Buf;

pub const Rendered = struct {
    human: []const u8,
    context: []const u8,
};

/// Collects numbered, dismissable items as the human view is rendered, so the
/// user can `jog dismiss <n>` afterwards. When a Picker is attached, each
/// dismissable line is prefixed with its number.
pub const Picker = struct {
    arena: std.mem.Allocator,
    items: std.ArrayList(dismiss.LastItem) = .empty,

    /// Record a dismissable item; returns its 1-based number.
    pub fn add(self: *Picker, pattern: []const u8, label: []const u8) u32 {
        self.items.append(self.arena, .{ .pattern = pattern, .label = label }) catch {};
        return @intCast(self.items.items.len);
    }
};

fn defaultSections(ctx: *Context) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    list.append(ctx.arena, "todos") catch {};
    list.append(ctx.arena, "git") catch {};
    for (ctx.cfg.plugins()) |p| list.append(ctx.arena, p.name) catch {};
    return list.items;
}

fn sectionList(ctx: *Context, override: ?[]const []const u8) []const []const u8 {
    if (override) |o| if (o.len > 0) return o;
    return ctx.cfg.getList("sections") orelse defaultSections(ctx);
}

const gathering_lines = [_][]const u8{
    "🔎 rummaging through your repos…",
    "🔎 retracing yesterday's steps…",
    "🔎 counting uncommitted sins…",
    "🔎 checking what you left open…",
    "🔎 waking up your repos…",
    "🔎 following the trail of loose ends…",
    "🔎 tallying branches and stashes…",
    "🔎 catching up on your git…",
    "🔎 seeing where you drifted off…",
};

const plugin_verbs = [_][]const u8{
    "poking", "asking", "pinging", "nudging", "consulting", "waking up", "checking in with", "shaking down",
};

fn pick(rnd: std.Random, comptime pool: []const []const u8) []const u8 {
    return pool[rnd.intRangeLessThan(usize, 0, pool.len)];
}

/// Render the global briefing across all discovered repos.
/// `network` selects whether plugin (network) sections may run.
/// `sections_override`, when non-null, replaces the configured section list.
pub fn renderGlobal(ctx: *Context, network: bool, sections_override: ?[]const []const u8, picker: ?*Picker) !Rendered {
    const roots = ctx.cfg.roots(ctx.env);
    const depth = ctx.cfg.getInt("depth", 3);
    const days = ctx.cfg.getInt("days", 7);
    const repos = discover_mod.discover(ctx.arena, ctx.io, ctx.env, roots, depth);

    var b: Buf = .init(ctx.arena); // human view
    var ai: Buf = .init(ctx.arena); // compact AI context
    const dismissed = dismiss.load(ctx);
    const t = ctx.theme;

    try b.printf("{s}◆ jog{s}  {s}· {s} · {s}{s}\n", .{
        t.accent_bold, t.reset,
        t.dim,         dt.pretty(ctx.arena, ctx.io), dt.greeting(ctx.io), t.reset,
    });
    try ai.printf("DEV STATUS for {s} (looking back {d} day(s)):\n", .{ dt.today(ctx.arena, ctx.io), days });

    var prng = std.Random.DefaultPrng.init(@bitCast(dt.nowEpoch(ctx.io)));
    const rnd = prng.random();

    for (sectionList(ctx, sections_override)) |name| {
        if (std.mem.eql(u8, name, "git")) {
            app.note(ctx.io, pick(rnd, &gathering_lines));
            try renderGitSection(ctx, &b, &ai, repos, dismissed, picker);
        } else if (std.mem.eql(u8, name, "todos") or std.mem.eql(u8, name, "reminders")) {
            try renderTodosSection(ctx, &b, &ai, null, dismissed);
        } else {
            app.note(ctx.io, std.fmt.allocPrint(ctx.arena, "🔌 {s} {s}…", .{ pick(rnd, &plugin_verbs), name }) catch "🔌 plugin…");
            try renderPluginSection(ctx, &b, &ai, name, repos, network, dismissed, null, picker);
        }
    }
    app.clearNote(ctx.io);

    try renderHint(ctx, &b);
    return .{ .human = b.items(), .context = ai.items() };
}

/// Append at most one short, context-aware hint that teaches a next step.
fn renderHint(ctx: *Context, b: *Buf) !void {
    if (!ctx.cfg.getBool("hints", true)) return;

    const t = ctx.theme;
    var open_todos: u32 = 0;
    for (todo.load(ctx.arena, ctx.io, ctx.paths.todos_file)) |t2| {
        if (!t2.done) open_todos += 1;
    }

    const tip: []const u8 = if (open_todos == 0)
        "track something for later:  jog todo add \"…\""
    else if (ctx.cfg.plugins().len == 0)
        "pull in more:  jog init  (auto-detects GitHub and more)"
    else
        "ask jog anything:  jog ask \"what should I focus on?\"";
    try b.printf("\n{s}💡 {s}{s}\n", .{ t.dim, tip, t.reset });
}

fn renderPluginSection(ctx: *Context, b: *Buf, ai: *Buf, name: []const u8, repos: []const []const u8, network: bool, dismissed: []const []const u8, repo_match: ?[]const u8, picker: ?*Picker) !void {
    if (!network) return;

    var command: ?[]const u8 = null;
    for (ctx.cfg.plugins()) |p| {
        if (std.mem.eql(u8, p.name, name)) command = p.command;
    }
    const cmd = command orelse return; // named in `sections` but not registered

    const res = plugin.run(ctx.arena, ctx.io, ctx.env, cmd, .{
        .repos = repos,
        .days = ctx.cfg.getInt("days", 7),
        .today = dt.today(ctx.arena, ctx.io),
    }, ctx.paths.env_file);

    const t = ctx.theme;
    if (res.err) |e| {
        try b.printf("\n{s}▌{s} {s}{s}{s}  {s}unavailable — {s}{s}\n", .{ t.gray, t.reset, t.bold, name, t.reset, t.dim, e, t.reset });
        return;
    }

    // Drop dismissed items first so counts and caps reflect what's shown.
    // In repo mode, also keep only items that mention the repo.
    var items: std.ArrayList(plugin.Item) = .empty;
    for (res.items) |it| {
        if (dismiss.matches(dismissed, it.title) or
            dismiss.matches(dismissed, it.note) or
            dismiss.matches(dismissed, it.url)) continue;
        if (repo_match) |rm| {
            if (!mentions(it, rm)) continue;
        }
        try items.append(ctx.arena, it);
    }
    if (items.items.len == 0) return;

    const max_key = try std.fmt.allocPrint(ctx.arena, "{s}.max", .{name});
    const max = ctx.cfg.getInt(max_key, 10);

    try sectionHeader(b, t, name, try std.fmt.allocPrint(ctx.arena, "{d}", .{items.items.len}));
    try ai.printf("\n{s} ({d} items):\n", .{ name, items.items.len });
    for (items.items, 0..) |it, idx| {
        // AI context: cap to a focused handful per section.
        if (idx < 8) {
            try ai.printf("- {s}", .{it.title});
            if (it.status.len > 0) try ai.printf(" [{s}]", .{it.status});
            if (it.note.len > 0) try ai.printf(" ({s})", .{it.note});
            try ai.append("\n");
        }
        if (idx >= max) {
            try b.printf("    {s}… and {d} more{s}\n", .{ t.dim, items.items.len - idx, t.reset });
            break;
        }
        if (picker) |pk| {
            const pat = if (it.url.len > 0) it.url else it.title;
            try b.printf("  {s}{d}{s} {s}", .{ t.accent, pk.add(pat, it.title), t.reset, it.title });
        } else {
            try b.printf("  {s}•{s} {s}", .{ t.accent, t.reset, it.title });
        }
        if (it.status.len > 0)
            try b.printf("  {s}[{s}{s}{s}{s}]{s}", .{ t.dim, t.reset, statusColor(t, it.status), it.status, t.dim, t.reset });
        try b.append("\n");
        if (it.note.len > 0) try b.printf("    {s}{s}{s}\n", .{ t.dim, it.note, t.reset });
        if (it.url.len > 0) try b.printf("    {s}{s}{s}\n", .{ t.blue, it.url, t.reset });
    }
}

/// Colorize a plugin status label by sentiment.
fn statusColor(t: anytype, status: []const u8) []const u8 {
    if (containsAnyIC(status, &.{ "fail", "block", "changes", "error", "overdue", "triggered" })) return t.red;
    if (containsAnyIC(status, &.{ "review", "pending", "wait", "progress", "acknowledged" })) return t.yellow;
    if (containsAnyIC(status, &.{ "done", "merged", "approved", "resolved", "ready" })) return t.green;
    return t.dim;
}

fn containsAnyIC(hay: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.ascii.indexOfIgnoreCase(hay, n) != null) return true;
    }
    return false;
}

/// Render a single repo's briefing (used by the on-cd hook). Git + todos only.
pub fn renderRepo(ctx: *Context, repo: []const u8) ![]const u8 {
    var b: Buf = .init(ctx.arena);
    var ai: Buf = .init(ctx.arena); // discarded; renderRepo is deterministic-only
    const days = ctx.cfg.getInt("days", 7);
    const max_commits = ctx.cfg.getInt("git.max_commits", 5);
    const f = git.facts(ctx.arena, ctx.io, repo, days, max_commits);

    try b.printf("{s}◆ {s}{s}", .{ ctx.theme.accent_bold, f.name, ctx.theme.reset });
    if (f.branch.len > 0) try b.printf("  {s}{s}{s}", .{ ctx.theme.dim, f.branch, ctx.theme.reset });
    try b.append("\n");
    try renderRepoFacts(ctx, &b, f, "  ");
    try renderTodosSection(ctx, &b, &ai, repo, dismiss.load(ctx));
    return b.items();
}

/// Context-aware brief for a single repo: its git state, its todos, and plugin
/// items belonging to it. Plugins run scoped to just this repo (JOG_REPOS = repo)
/// and their items are additionally filtered to those mentioning the repo name.
pub fn renderRepoFull(ctx: *Context, repo: []const u8, network: bool) !Rendered {
    const days = ctx.cfg.getInt("days", 7);
    const max_commits = ctx.cfg.getInt("git.max_commits", 5);
    const dismissed = dismiss.load(ctx);
    const f = git.facts(ctx.arena, ctx.io, repo, days, max_commits);
    const only = try ctx.arena.dupe([]const u8, &.{repo});

    var b: Buf = .init(ctx.arena);
    var ai: Buf = .init(ctx.arena);

    try b.printf("{s}◆ {s}{s}", .{ ctx.theme.accent_bold, f.name, ctx.theme.reset });
    if (f.branch.len > 0) try b.printf("  {s}{s}{s}", .{ ctx.theme.dim, f.branch, ctx.theme.reset });
    try b.append("\n");
    try renderRepoFacts(ctx, &b, f, "  ");

    try ai.printf("REPO STATUS for {s}", .{f.name});
    if (f.branch.len > 0) try ai.printf(" (branch {s})", .{f.branch});
    try ai.printf(" on {s}:\n", .{dt.today(ctx.arena, ctx.io)});
    try ai.printf("- {d} uncommitted, {d} unpushed, {d} stashed\n", .{ f.dirty, f.unpushed, f.stashes });
    if (f.commits.len > 0) {
        try ai.append("recent commits:\n");
        for (f.commits) |c| try ai.printf("- {s}\n", .{c});
    }

    try renderTodosSection(ctx, &b, &ai, repo, dismissed);

    if (network) {
        for (sectionList(ctx, null)) |name| {
            if (std.mem.eql(u8, name, "git") or std.mem.eql(u8, name, "todos")) continue;
            app.note(ctx.io, std.fmt.allocPrint(ctx.arena, "🔌 {s}…", .{name}) catch "🔌 plugin…");
            try renderPluginSection(ctx, &b, &ai, name, only, true, dismissed, f.name, null);
        }
        app.clearNote(ctx.io);
    }

    return .{ .human = b.items(), .context = ai.items() };
}

/// Render open todos. Dated todos sort to the top (overdue → today → upcoming),
/// marked with their day; undated todos follow. When `repo_filter` is set, shows
/// global todos plus those scoped to that repo.
fn renderTodosSection(ctx: *Context, b: *Buf, ai: *Buf, repo_filter: ?[]const u8, dismissed: []const []const u8) !void {
    const all = todo.load(ctx.arena, ctx.io, ctx.paths.todos_file);
    const today = dt.today(ctx.arena, ctx.io);
    const max = ctx.cfg.getInt("todos.max", 10);

    var items: std.ArrayList(todo.Todo) = .empty;
    for (all) |t| {
        if (t.done) continue;
        if (dismiss.matches(dismissed, t.text)) continue;
        if (repo_filter) |rf| {
            if (t.repo.len != 0 and !std.mem.eql(u8, t.repo, rf)) continue;
        }
        try items.append(ctx.arena, t);
    }
    if (items.items.len == 0) return;

    std.mem.sort(todo.Todo, items.items, {}, lessThanTodo);

    const th = ctx.theme;
    try sectionHeader(b, th, "todos", try std.fmt.allocPrint(ctx.arena, "{d}", .{items.items.len}));
    try ai.printf("\nTODOS ({d}) — dated ones are time-sensitive, surface them first:\n", .{items.items.len});
    var shown: u32 = 0;
    for (items.items) |t| {
        const scope = if (t.repo.len == 0) "" else std.fs.path.basename(t.repo);

        // AI context line.
        if (t.due.len > 0) {
            try ai.printf("- {s} (due {s}, {s})", .{ t.text, t.due, when.describe(ctx.arena, today, t.due) });
        } else {
            try ai.printf("- {s}", .{t.text});
        }
        if (scope.len > 0) try ai.printf(" [{s}]", .{scope});
        try ai.append("\n");

        if (shown >= max) {
            try b.printf("    {s}… and {d} more{s}\n", .{ th.dim, items.items.len - shown, th.reset });
            break;
        }

        // Human line: dated todos get a colored urgency marker + relative day.
        if (t.due.len > 0) {
            const overdue = std.mem.order(u8, t.due, today) == .lt;
            const due_today = std.mem.eql(u8, t.due, today);
            const icon = if (overdue) "⚠" else if (due_today) "●" else "○";
            const col = if (overdue) th.red else if (due_today) th.green else th.gray;
            try b.printf("  {s}{s}{s} {s}{d}{s} {s}  {s}— {s}", .{ col, icon, th.reset, th.dim, t.id, th.reset, t.text, th.dim, when.describe(ctx.arena, today, t.due) });
            if (scope.len > 0) try b.printf(" · {s}", .{scope});
            try b.append(th.reset);
            try b.append("\n");
        } else {
            try b.printf("  {s}▫{s} {s}{d}{s} {s}", .{ th.gray, th.reset, th.dim, t.id, th.reset, t.text });
            if (scope.len > 0) try b.printf("  {s}· {s}{s}", .{ th.dim, scope, th.reset });
            try b.append("\n");
        }
        shown += 1;
    }
}

/// Sort: dated todos first (earliest due first), then undated (by id).
fn lessThanTodo(_: void, a: todo.Todo, b: todo.Todo) bool {
    const ad = a.due.len > 0;
    const bd = b.due.len > 0;
    if (ad != bd) return ad;
    if (ad) return std.mem.order(u8, a.due, b.due) == .lt;
    return a.id < b.id;
}

fn renderGitSection(ctx: *Context, b: *Buf, ai: *Buf, repos: []const []const u8, dismissed: []const []const u8, picker: ?*Picker) !void {
    const days = ctx.cfg.getInt("days", 7);
    const max_commits = ctx.cfg.getInt("git.max_commits", 5);

    var active: std.ArrayList(git.RepoFacts) = .empty;
    for (repos) |repo| {
        const f = git.facts(ctx.arena, ctx.io, repo, days, max_commits);
        if (!f.hasActivity()) continue;
        if (dismiss.matches(dismissed, f.name) or dismiss.matches(dismissed, f.path)) continue;
        try active.append(ctx.arena, f);
    }

    const t = ctx.theme;
    try sectionHeader(b, t, "git", try std.fmt.allocPrint(ctx.arena, "{d} active · {d}d", .{ active.items.len, days }));
    try ai.printf("\nGIT ({d} active repos):\n", .{active.items.len});
    if (active.items.len == 0) {
        try b.printf("  {s}nothing recent{s}\n", .{ t.dim, t.reset });
        return;
    }
    for (active.items) |f| {
        if (picker) |pk| {
            try b.printf("\n  {s}{d}{s} {s}{s}{s}{s}", .{ t.accent, pk.add(f.name, f.name), t.reset, t.bold, t.cyan, f.name, t.reset });
        } else {
            try b.printf("\n  {s}{s}{s}{s}", .{ t.bold, t.cyan, f.name, t.reset });
        }
        if (f.branch.len > 0) try b.printf("  {s}{s}{s}", .{ t.dim, f.branch, t.reset });
        try b.append("\n");
        try renderRepoFacts(ctx, b, f, "    ");

        // Compact AI line per repo.
        try ai.printf("- {s}", .{f.name});
        if (f.branch.len > 0) try ai.printf(" [{s}]", .{f.branch});
        try ai.printf(": {d} uncommitted, {d} unpushed, {d} stashed", .{ f.dirty, f.unpushed, f.stashes });
        if (f.commits.len > 0) {
            try ai.append(" | recent: ");
            for (f.commits, 0..) |c, i| {
                if (i >= 2) break;
                if (i != 0) try ai.append("; ");
                try ai.append(c);
            }
        }
        try ai.append("\n");
    }
}

fn renderRepoFacts(ctx: *Context, b: *Buf, f: git.RepoFacts, indent: []const u8) !void {
    const show = ctx.cfg.getOr("git.show", "branch,commits,dirty,unpushed,stash");
    const t = ctx.theme;

    if (contains(show, "dirty") and f.dirty > 0)
        try b.printf("{s}{s}●{s} {d} uncommitted\n", .{ indent, t.red, t.reset, f.dirty });
    if (contains(show, "unpushed") and f.unpushed > 0)
        try b.printf("{s}{s}↑{s} {d} unpushed\n", .{ indent, t.yellow, t.reset, f.unpushed });
    if (contains(show, "stash") and f.stashes > 0)
        try b.printf("{s}{s}≡{s} {d} stashed\n", .{ indent, t.magenta, t.reset, f.stashes });
    if (contains(show, "commits") and f.commits.len > 0) {
        for (f.commits) |c| {
            // "hash subject" → dim the hash, normal subject.
            const sp = std.mem.indexOfScalar(u8, c, ' ') orelse c.len;
            try b.printf("{s}{s}{s}{s} {s}\n", .{ indent, t.gray, c[0..sp], t.reset, if (sp < c.len) c[sp + 1 ..] else "" });
        }
    }
}

fn sectionHeader(b: *Buf, t: anytype, name: []const u8, meta: []const u8) !void {
    try b.printf("\n{s}▌{s} {s}{s}{s}", .{ t.accent, t.reset, t.bold, name, t.reset });
    if (meta.len > 0) try b.printf("  {s}{s}{s}", .{ t.dim, meta, t.reset });
    try b.append("\n");
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Whether a plugin item references the given repo name (title/note/url).
fn mentions(it: plugin.Item, repo: []const u8) bool {
    return contains(it.title, repo) or contains(it.note, repo) or contains(it.url, repo);
}
