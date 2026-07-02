const std = @import("std");
const config_mod = @import("config.zig");
const paths_mod = @import("paths.zig");
const discover_mod = @import("discover.zig");
const git = @import("git.zig");
const app = @import("app.zig");
const briefing = @import("briefing.zig");
const todo = @import("todo.zig");
const seen = @import("seen.zig");
const shell = @import("shell.zig");
const dt = @import("dt.zig");
const plugin = @import("plugin.zig");
const bootstrap = @import("bootstrap.zig");
const ai = @import("ai.zig");
const dismiss = @import("dismiss.zig");
const todo_when = @import("when.zig");
const ui = @import("ui.zig");

const Context = app.Context;
const Buf = app.Buf;
const writeOut = app.writeOut;

const usage =
    \\jog — jogs your memory at the start of the day.
    \\
    \\Usage:
    \\  jog [brief]              Show the briefing (AI-summarized by default)
    \\  jog brief --full         Full deterministic briefing (no AI)
    \\  jog brief --ai           Force the AI summary
    \\  jog brief <section…>     Only these sections, e.g. `jog brief github git`
    \\  jog brief --days <n>     Override the lookback window for this run
    \\  jog brief --refresh      Re-run AI even if a cached brief exists
    \\  jog .                    Context-aware brief for the current repo
    \\  jog <path>               Context-aware brief for a repo at <path>
    \\  jog ask "<question>"     Ask AI about your current work
    \\  jog tidy [--apply]       AI review of your todos; --apply rewrites them (backs up)
    \\  jog dismiss              Show a numbered list of items you can hide
    \\  jog dismiss <number>     Hide the numbered item from the list
    \\  jog dismiss "<text>"     Hide anything matching <text>
    \\  jog dismiss --list|--clear
    \\  jog config               Print effective config (and its path)
    \\  jog init                 Write a commented default config file
    \\  jog scan                 List auto-discovered git repos
    \\  jog todo add <text>      Add a todo (--repo . to scope; --due <when> to date it)
    \\  jog remind <when> <text> Shortcut for a dated todo (tomorrow, fri, 3d, 2026-07-20)
    \\  jog todo list [--all]    List todos (dated ones show their day)
    \\  jog todo done <id>       Mark a todo done
    \\  jog todo snooze <id> <when>  Move a todo's due date
    \\  jog todo rm <id>         Remove a todo
    \\  jog plugin new <n>       Scaffold a new plugin (--ai "<desc>" to have AI write it)
    \\  jog plugin list          List registered plugins
    \\  jog plugin add <n> <cmd> Register an existing command as a plugin
    \\  jog plugin edit <n>      Show a plugin's script path
    \\  jog plugin rm <n>        Unregister a plugin
    \\  jog plugin run <n>       Run a plugin and print its items
    \\  jog shell-init <shell>   Print the shell hook for zsh|bash
    \\  jog help                 Show this help
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const cmd: []const u8 = if (args.len >= 2) args[1] else "brief";
    const rest: []const [:0]const u8 = if (args.len >= 2) args[2..] else &.{};

    if (eql(cmd, "help") or eql(cmd, "-h") or eql(cmd, "--help")) {
        try writeOut(init.io, usage);
        return;
    }

    const paths = try paths_mod.resolve(arena, init.environ_map);
    const cfg = try config_mod.load(arena, init.io, paths.config_file);

    var ctx: Context = .{
        .arena = arena,
        .gpa = init.gpa,
        .io = init.io,
        .env = init.environ_map,
        .paths = paths,
        .cfg = cfg,
        .theme = ui.Theme.init(ui.colorEnabled(init.io, init.environ_map)),
    };

    // First-run auto-setup: install bundled plugins and register the available
    // ones, so a bare `jog` lights up with zero config. Skipped for the silent
    // shell hooks and for `init` (which bootstraps explicitly with output).
    if (!ctx.cfg.loaded_from_file and
        !eql(cmd, "_entered") and !eql(cmd, "shell-init") and !eql(cmd, "init"))
    {
        _ = bootstrap.install(&ctx);
        ctx.cfg = try config_mod.load(arena, init.io, paths.config_file);
    }

    if (eql(cmd, "config")) {
        try cmdConfig(&ctx);
    } else if (eql(cmd, "init")) {
        try cmdInit(&ctx);
    } else if (eql(cmd, "scan")) {
        try cmdScan(&ctx);
    } else if (eql(cmd, "brief")) {
        try cmdBrief(&ctx, rest);
    } else if (isPathish(cmd)) {
        try cmdRepoBrief(&ctx, cmd, rest);
    } else if (eql(cmd, "todo")) {
        try cmdTodo(&ctx, rest);
    } else if (eql(cmd, "remind")) {
        try cmdRemind(&ctx, rest);
    } else if (eql(cmd, "ask")) {
        try cmdAsk(&ctx, rest);
    } else if (eql(cmd, "tidy")) {
        try cmdTidy(&ctx, rest);
    } else if (eql(cmd, "dismiss")) {
        try cmdDismiss(&ctx, rest);
    } else if (eql(cmd, "plugin")) {
        try cmdPlugin(&ctx, rest);
    } else if (eql(cmd, "shell-init")) {
        try cmdShellInit(&ctx, rest);
    } else if (eql(cmd, "_entered")) {
        try cmdEntered(&ctx, rest);
    } else {
        var b: Buf = .init(arena);
        try b.printf("jog: unknown command '{s}' (try `jog help`)\n", .{cmd});
        try writeOut(ctx.io, b.items());
    }
}

fn cmdBrief(ctx: *Context, rest: []const [:0]const u8) !void {
    var force_ai = false; // --ai
    var force_full = false; // --full / --no-ai / --raw
    var refresh = false; // --refresh (bypass AI cache)
    var numbers = false; // -n / --numbers (numbered, deterministic, for dismiss)
    var sections: std.ArrayList([]const u8) = .empty; // positional section filter

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (eql(a, "--repo") and i + 1 < rest.len) {
            // Single-repo view is already short; always deterministic.
            const out = try briefing.renderRepo(ctx, rest[i + 1]);
            try writeOut(ctx.io, out);
            return;
        } else if (eql(a, "--ai")) {
            force_ai = true;
        } else if (eql(a, "--full") or eql(a, "--no-ai") or eql(a, "--raw")) {
            force_full = true;
        } else if (eql(a, "--refresh")) {
            refresh = true;
        } else if (eql(a, "-n") or eql(a, "--numbers")) {
            numbers = true;
        } else if (eql(a, "--days") and i + 1 < rest.len) {
            // Override the lookback window for this run.
            try ctx.cfg.entries.insert(ctx.arena, 0, .{ .key = "days", .value = rest[i + 1] });
            i += 1;
        } else if (!std.mem.startsWith(u8, a, "-")) {
            try sections.append(ctx.arena, a);
        }
    }

    const override: ?[]const []const u8 = if (sections.items.len > 0) sections.items else null;

    // Numbered, deterministic view: each dismissable item gets a number you can
    // pass to `jog dismiss <n>`.
    if (numbers) {
        try writeOut(ctx.io, try numberedBrief(ctx, override));
        return;
    }

    const has_ai = ctx.cfg.getOr("ai_command", "").len > 0;
    const use_ai = has_ai and (force_ai or (!force_full and ctx.cfg.getBool("ai_enabled", true)));

    // Fast path: a recent cached brief lets quick repeat runs skip all gathering
    // and the AI call. Auto-expires after cache_ttl; --refresh forces a rebuild.
    const ttl = ctx.cfg.getInt("cache_ttl", 900);
    const cache_key = try std.fmt.allocPrint(ctx.arena, "{s}|{s}|{d}", .{
        ctx.cfg.getOr("ai_command", ""),
        if (override) |o| try std.mem.join(ctx.arena, ",", o) else "default",
        ctx.cfg.getInt("days", 7),
    });
    if (use_ai and !refresh) {
        if (ai.briefCacheGet(ctx, cache_key, ttl)) |cached| {
            try writeOut(ctx.io, cached);
            return;
        }
    }

    const rendered = try briefing.renderGlobal(ctx, true, override, null);
    const header = try std.fmt.allocPrint(ctx.arena, "{s}◆ jog{s} {s}· your brief{s}\n\n", .{ ctx.theme.accent_bold, ctx.theme.reset, ctx.theme.dim, ctx.theme.reset });
    try emitBrief(ctx, rendered, cache_key, use_ai, header);
}

/// Render the deterministic brief with each dismissable item numbered, and save
/// the numbering so `jog dismiss <n>` can resolve items by number.
fn numberedBrief(ctx: *Context, override: ?[]const []const u8) ![]const u8 {
    var picker: briefing.Picker = .{ .arena = ctx.arena };
    const rendered = try briefing.renderGlobal(ctx, true, override, &picker);
    dismiss.saveLast(ctx, picker.items.items);

    var b: Buf = .init(ctx.arena);
    try b.append(rendered.human);
    if (picker.items.items.len > 0) {
        try b.append("\n\x1b[2mhide one:  jog dismiss <number>\x1b[0m\n");
    }
    return b.items();
}

/// Context-aware brief for a single repo: `jog .` or `jog <path>`.
fn cmdRepoBrief(ctx: *Context, repo_arg: []const u8, rest: []const [:0]const u8) !void {
    var force_ai = false;
    var force_full = false;
    var refresh = false;
    for (rest) |a| {
        if (eql(a, "--ai")) force_ai = true;
        if (eql(a, "--full") or eql(a, "--no-ai") or eql(a, "--raw")) force_full = true;
        if (eql(a, "--refresh")) refresh = true;
    }

    const repo = repoRoot(ctx, repo_arg) orelse {
        var b: Buf = .init(ctx.arena);
        try b.printf("not a git repo: {s}\n", .{repo_arg});
        try writeOut(ctx.io, b.items());
        return;
    };
    const name = std.fs.path.basename(repo);

    const has_ai = ctx.cfg.getOr("ai_command", "").len > 0;
    const use_ai = has_ai and (force_ai or (!force_full and ctx.cfg.getBool("ai_enabled", true)));

    const cache_key = try std.fmt.allocPrint(ctx.arena, "repo:{s}|{s}", .{ repo, ctx.cfg.getOr("ai_command", "") });
    const ttl = ctx.cfg.getInt("cache_ttl", 900);
    if (use_ai and !refresh) {
        if (ai.briefCacheGet(ctx, cache_key, ttl)) |cached| {
            try writeOut(ctx.io, cached);
            return;
        }
    }

    const rendered = try briefing.renderRepoFull(ctx, repo, true);
    const header = try std.fmt.allocPrint(ctx.arena, "{s}◆ {s}{s} {s}· your brief{s}\n\n", .{ ctx.theme.accent_bold, name, ctx.theme.reset, ctx.theme.dim, ctx.theme.reset });
    try emitBrief(ctx, rendered, cache_key, use_ai, header);
}

/// Shared brief emitter: stream an AI summary (live) and cache it, or print the
/// full deterministic view.
fn emitBrief(ctx: *Context, rendered: briefing.Rendered, cache_key: []const u8, use_ai: bool, header: []const u8) !void {
    const t = ctx.theme;
    if (use_ai) {
        try writeOut(ctx.io, header);
        if (ai.summarizeStream(ctx, rendered.context)) |recap| {
            const footer = try std.fmt.allocPrint(ctx.arena, "\n{s}› add --full for details · jog ask \"…\" to dig in{s}\n", .{ t.dim, t.reset });
            try writeOut(ctx.io, footer);
            const full = try std.fmt.allocPrint(ctx.arena, "{s}{s}{s}", .{ header, recap, footer });
            ai.briefCachePut(ctx, cache_key, full);
            return;
        }
        try writeOut(ctx.io, try std.fmt.allocPrint(ctx.arena, "{s}AI unavailable — showing the full briefing{s}\n", .{ t.dim, t.reset }));
    }
    try writeOut(ctx.io, rendered.human);
}

/// Resolve a repo argument ("." or a path) to its git toplevel, or null.
fn repoRoot(ctx: *Context, arg: []const u8) ?[]const u8 {
    const cwd: []const u8 = if (eql(arg, ".")) "." else arg;
    if (git.run(ctx.arena, ctx.io, cwd, &.{ "rev-parse", "--show-toplevel" })) |top| {
        if (top.len > 0) return top;
    }
    return null;
}

/// Turn a free-text description into a short, safe plugin name (first ~3 words).
fn slugify(arena: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var words: u32 = 0;
    var at_boundary = true; // suppress leading dashes
    for (s) |c| {
        const lc = std.ascii.toLower(c);
        if ((lc >= 'a' and lc <= 'z') or (lc >= '0' and lc <= '9')) {
            out.append(arena, lc) catch break;
            at_boundary = false;
        } else if (!at_boundary) {
            words += 1;
            if (words >= 3) break;
            out.append(arena, '-') catch break;
            at_boundary = true;
        }
    }
    var res = out.items;
    while (res.len > 0 and res[res.len - 1] == '-') res = res[0 .. res.len - 1];
    return if (res.len == 0) "plugin" else res;
}

/// Pull the script path out of a `sh '<path>'` plugin command, if present.
fn extractPath(command: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, command, '\'') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, command, '\'') orelse return null;
    if (close <= open + 1) return null;
    return command[open + 1 .. close];
}

/// Whether a command token looks like a filesystem path (→ repo brief).
fn isPathish(s: []const u8) bool {
    if (eql(s, ".") or eql(s, "..")) return true;
    return std.mem.startsWith(u8, s, "/") or
        std.mem.startsWith(u8, s, "./") or
        std.mem.startsWith(u8, s, "../") or
        std.mem.startsWith(u8, s, "~/");
}

fn cmdAsk(ctx: *Context, rest: []const [:0]const u8) !void {
    var b: Buf = .init(ctx.arena);

    var q: std.ArrayList(u8) = .empty;
    for (rest) |tok| {
        if (std.mem.startsWith(u8, tok, "-")) continue;
        if (q.items.len > 0) try q.append(ctx.arena, ' ');
        try q.appendSlice(ctx.arena, tok);
    }
    if (q.items.len == 0) {
        try b.append("usage: jog ask \"<question about your current work>\"\n");
        try writeOut(ctx.io, b.items());
        return;
    }

    const rendered = try briefing.renderGlobal(ctx, true, null, null);
    // ai.ask streams its answer to stdout directly.
    if (ai.ask(ctx, rendered.context, q.items) == null) {
        try b.append("AI is unavailable. Set `ai_command` (e.g. `ollama run qwen2.5`) in `jog config`'s file, or run `jog init`.\n");
        try writeOut(ctx.io, b.items());
    } else {
        try writeOut(ctx.io, "\n");
    }
}

/// AI cleanup of your todos. Default: advisory review (streamed, never edits).
/// `--apply`: rewrite your todos with the cleaned list (backs up first).
fn cmdTidy(ctx: *Context, rest: []const [:0]const u8) !void {
    var b: Buf = .init(ctx.arena);
    var apply = false;
    var confirmed = false;
    for (rest) |a| {
        if (eql(a, "--apply") or eql(a, "apply")) apply = true;
        if (eql(a, "--yes") or eql(a, "-y")) confirmed = true;
    }

    const todos = todo.load(ctx.arena, ctx.io, ctx.paths.todos_file);
    var list: Buf = .init(ctx.arena);
    var n: u32 = 0;
    for (todos) |t| {
        if (t.done) continue;
        n += 1;
        try list.printf("[{d}] {s}", .{ t.id, t.text });
        if (t.repo.len > 0) try list.printf(" (repo: {s})", .{std.fs.path.basename(t.repo)});
        if (t.due.len > 0) try list.printf(" (due {s})", .{t.due});
        try list.append("\n");
    }
    if (n == 0) {
        try b.append("no open todos to tidy — you're clear.\n");
        try writeOut(ctx.io, b.items());
        return;
    }
    if (!ai.available(ctx)) {
        try b.append("AI is unavailable. Set `ai_command` in `jog config`'s file, or run `jog init`.\n");
        try writeOut(ctx.io, b.items());
        return;
    }

    if (!apply) {
        const prompt = try std.fmt.allocPrint(ctx.arena,
            \\You are my todo assistant. Today is {s}. Here is my open todo list.
            \\Help me tidy it: call out duplicates or overlaps to merge, vague or
            \\likely-stale items to drop, and suggest clearer wording where useful.
            \\Be brief and concrete, referencing the [numbers]. Finish with "Do first:"
            \\and the 2-3 that matter most today. (Run `jog tidy --apply` to apply.)
            \\
            \\{s}
        , .{ dt.today(ctx.arena, ctx.io), list.items() });
        _ = ai.stream(ctx, prompt);
        try writeOut(ctx.io, "\n");
        return;
    }

    // --apply: get a structured cleaned list. Conservative prompt: never invent
    // or silently drop tasks; only merge genuine duplicates.
    const prompt = try std.fmt.allocPrint(ctx.arena,
        \\Tidy this todo list CONSERVATIVELY. Rules:
        \\- Keep every distinct task. Do NOT drop anything unless it is a clear
        \\  duplicate of another item.
        \\- Only merge items that are truly the same task; list their ids in "from".
        \\- You may rewrite wording to be clearer and more concise, but preserve
        \\  each task's meaning. Do not invent new tasks.
        \\Return ONLY a JSON array — each element
        \\{{"text": "<cleaned todo>", "from": [<original id numbers>]}}. No prose.
        \\
        \\{s}
    , .{list.items()});

    const raw = ai.complete(ctx, prompt) orelse {
        try b.append("AI is unavailable right now — no changes made.\n");
        try writeOut(ctx.io, b.items());
        return;
    };
    const json = extractJsonArray(raw) orelse {
        try b.append("couldn't understand the AI's output — no changes made.\n");
        try writeOut(ctx.io, b.items());
        return;
    };

    const Item = struct { text: []const u8 = "", from: []const u32 = &.{} };
    const items = std.json.parseFromSliceLeaky([]Item, ctx.arena, json, .{ .ignore_unknown_fields = true }) catch {
        try b.append("the AI returned invalid JSON — no changes made.\n");
        try writeOut(ctx.io, b.items());
        return;
    };
    if (items.len == 0) {
        try b.append("the AI returned nothing — no changes made.\n");
        try writeOut(ctx.io, b.items());
        return;
    }

    // Build the proposed new list: keep done todos, replace open ones with the
    // cleaned set, inheriting repo/due/created from the first original id.
    var final: std.ArrayList(todo.Todo) = .empty;
    for (todos) |t| {
        if (t.done) try final.append(ctx.arena, t);
    }
    for (items) |it| {
        if (it.text.len == 0) continue;
        var repo: []const u8 = "";
        var due: []const u8 = "";
        var created = dt.today(ctx.arena, ctx.io);
        for (it.from) |fid| {
            for (todos) |t| {
                if (t.id == fid and !t.done) {
                    repo = t.repo;
                    due = t.due;
                    created = t.created;
                    break;
                }
            }
            if (repo.len > 0 or due.len > 0) break;
        }
        try final.append(ctx.arena, .{
            .id = 0,
            .done = false,
            .created = created,
            .repo = repo,
            .text = cleanText(ctx.arena, it.text),
            .due = due,
        });
    }

    // Which open todos would be dropped (not referenced by any item's "from")?
    var dropped: std.ArrayList(todo.Todo) = .empty;
    for (todos) |t| {
        if (t.done) continue;
        var kept = false;
        for (items) |it| {
            for (it.from) |fid| if (fid == t.id) {
                kept = true;
            };
        }
        if (!kept) try dropped.append(ctx.arena, t);
    }

    if (!confirmed) {
        // Preview only — never write without --yes.
        try b.printf("proposed: {d} open todo(s) → {d}\n\n", .{ n, items.len });
        for (final.items) |t| {
            if (t.done) continue;
            try b.printf("  [{d}] {s}\n", .{ t.id, t.text });
        }
        if (dropped.items.len > 0) {
            try b.printf("\n\x1b[33m⚠ would DROP {d} todo(s):\x1b[0m\n", .{dropped.items.len});
            for (dropped.items) |t| try b.printf("  ✗ {s}\n", .{t.text});
        }
        try b.append("\nnothing changed. to apply:  jog tidy --apply --yes\n");
        try writeOut(ctx.io, b.items());
        return;
    }

    todo.backup(ctx.arena, ctx.io, ctx.paths.todos_file);
    try todo.saveAll(ctx.arena, ctx.io, ctx.paths.dir, ctx.paths.todos_file, final.items);

    try b.printf("tidied {d} todo(s) → {d}. backup: {s}.bak\n", .{ n, items.len, ctx.paths.todos_file });
    try b.printf("  undo:  cp \"{s}.bak\" \"{s}\"\n", .{ ctx.paths.todos_file, ctx.paths.todos_file });
    for (final.items) |t| {
        if (t.done) continue;
        try b.printf("  [{d}] {s}\n", .{ t.id, t.text });
    }
    try writeOut(ctx.io, b.items());
}

/// Slice out the first JSON array (`[` … matching `]`) from arbitrary text.
fn extractJsonArray(s: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, s, '[') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, s, ']') orelse return null;
    if (close <= open) return null;
    return s[open .. close + 1];
}

/// Flatten tabs/newlines so a value stays on one TSV line.
fn cleanText(arena: std.mem.Allocator, s: []const u8) []const u8 {
    const out = arena.alloc(u8, s.len) catch return s;
    for (s, 0..) |c, i| out[i] = if (c == '\t' or c == '\n' or c == '\r') ' ' else c;
    return std.mem.trim(u8, out, " ");
}

fn cmdDismiss(ctx: *Context, rest: []const [:0]const u8) !void {
    var b: Buf = .init(ctx.arena);
    const sub: []const u8 = if (rest.len >= 1) rest[0] else "";

    if (rest.len == 0) {
        // No args: show the numbered list and tell the user how to pick.
        try writeOut(ctx.io, try numberedBrief(ctx, null));
        return;
    } else if (eql(sub, "--list") or eql(sub, "list")) {
        const patterns = dismiss.load(ctx);
        if (patterns.len == 0) {
            try b.append("nothing dismissed.\n  run `jog dismiss` to pick something to hide\n");
        } else {
            try b.printf("dismissed ({d}):\n", .{patterns.len});
            for (patterns) |p| try b.printf("  {s}\n", .{p});
        }
    } else if (eql(sub, "--clear") or eql(sub, "clear")) {
        try dismiss.clear(ctx);
        ai.clearBriefCache(ctx);
        try b.append("cleared all dismissals.\n");
    } else if (std.fmt.parseInt(u32, sub, 10)) |n| {
        // A number refers to an item from the last numbered brief.
        if (dismiss.getLast(ctx, n)) |item| {
            try dismiss.add(ctx, item.pattern);
            ai.clearBriefCache(ctx);
            try b.printf("dismissed #{d}: {s} — jog won't mention it again (jog dismiss --clear to undo)\n", .{ n, item.label });
        } else {
            try b.printf("no item #{d}. run `jog dismiss` to see the numbered list.\n", .{n});
        }
    } else |_| {
        // Otherwise treat the whole argument as a text pattern.
        var pat: std.ArrayList(u8) = .empty;
        for (rest) |tok| {
            if (pat.items.len > 0) try pat.append(ctx.arena, ' ');
            try pat.appendSlice(ctx.arena, tok);
        }
        try dismiss.add(ctx, pat.items);
        ai.clearBriefCache(ctx);
        try b.printf("dismissed: \"{s}\" — jog won't mention it again (jog dismiss --clear to undo)\n", .{pat.items});
    }
    try writeOut(ctx.io, b.items());
}

fn cmdTodo(ctx: *Context, rest: []const [:0]const u8) !void {
    var b: Buf = .init(ctx.arena);
    const sub: []const u8 = if (rest.len >= 1) rest[0] else "list";

    if (eql(sub, "add")) {
        // Collect text tokens, pulling out optional `--repo <val>` / `--due <when>`.
        var repo: []const u8 = "";
        var due: []const u8 = "";
        var bad_due: ?[]const u8 = null;
        var text: std.ArrayList(u8) = .empty;
        var i: usize = 1;
        while (i < rest.len) : (i += 1) {
            if (eql(rest[i], "--repo") and i + 1 < rest.len) {
                repo = try resolveRepoArg(ctx, rest[i + 1]);
                i += 1;
                continue;
            }
            if ((eql(rest[i], "--due") or eql(rest[i], "--on") or eql(rest[i], "--in")) and i + 1 < rest.len) {
                if (todo_when.parse(ctx.arena, ctx.io, rest[i + 1])) |d| due = d else bad_due = rest[i + 1];
                i += 1;
                continue;
            }
            if (text.items.len > 0) try text.append(ctx.arena, ' ');
            try text.appendSlice(ctx.arena, rest[i]);
        }
        if (bad_due) |w| {
            try b.printf("didn't understand the date '{s}'. Try: today, tomorrow, fri, 3d, 2w, 2026-07-20\n", .{w});
        } else if (text.items.len == 0) {
            try b.append("usage: jog todo add <text> [--repo .|<path>] [--due <when>]\n");
        } else {
            const id = try todo.add(ctx.arena, ctx.io, ctx.paths.dir, ctx.paths.todos_file, repo, text.items, due);
            if (due.len > 0) {
                try b.printf("added todo [{d}] — due {s} ({s})\n", .{ id, due, todo_when.describe(ctx.arena, dt.today(ctx.arena, ctx.io), due) });
            } else {
                try b.printf("added todo [{d}]\n", .{id});
            }
        }
    } else if (eql(sub, "snooze") or eql(sub, "due")) {
        // jog todo snooze <id> <when>   /   jog todo due <id> <when>
        if (rest.len < 3) {
            try b.printf("usage: jog todo {s} <id> <when>\n", .{sub});
        } else if (std.fmt.parseInt(u32, rest[1], 10)) |id| {
            if (todo_when.parse(ctx.arena, ctx.io, rest[2])) |d| {
                const ok = try todo.setDue(ctx.arena, ctx.io, ctx.paths.dir, ctx.paths.todos_file, id, d);
                if (ok) {
                    try b.printf("todo [{d}] due {s} ({s})\n", .{ id, d, todo_when.describe(ctx.arena, dt.today(ctx.arena, ctx.io), d) });
                } else {
                    try b.printf("no todo with id {d}\n", .{id});
                }
            } else {
                try b.printf("didn't understand '{s}'. Try: today, tomorrow, fri, 3d, 2026-07-20\n", .{rest[2]});
            }
        } else |_| {
            try b.printf("invalid id '{s}'\n", .{rest[1]});
        }
    } else if (eql(sub, "list")) {
        var repo_filter: ?[]const u8 = null;
        var show_all = false;
        var i: usize = 1;
        while (i < rest.len) : (i += 1) {
            if (eql(rest[i], "--all")) show_all = true;
            if (eql(rest[i], "--repo") and i + 1 < rest.len) {
                repo_filter = try resolveRepoArg(ctx, rest[i + 1]);
                i += 1;
            }
        }
        const todos = todo.load(ctx.arena, ctx.io, ctx.paths.todos_file);
        var count: u32 = 0;
        for (todos) |t| {
            if (!show_all and t.done) continue;
            if (repo_filter) |rf| {
                if (t.repo.len != 0 and !std.mem.eql(u8, t.repo, rf)) continue;
            }
            const th = ctx.theme;
            const today = dt.today(ctx.arena, ctx.io);
            const mark = if (t.done)
                try std.fmt.allocPrint(ctx.arena, "{s}✓{s}", .{ th.green, th.reset })
            else
                try std.fmt.allocPrint(ctx.arena, "{s}▫{s}", .{ th.gray, th.reset });
            const scope = if (t.repo.len == 0) "" else std.fs.path.basename(t.repo);
            const due_note = if (t.due.len > 0) blk: {
                const overdue = std.mem.order(u8, t.due, today) == .lt;
                const col = if (t.done) th.dim else if (overdue) th.red else th.dim;
                break :blk try std.fmt.allocPrint(ctx.arena, "  {s}⏰ {s}{s}", .{ col, todo_when.describe(ctx.arena, today, t.due), th.reset });
            } else "";
            const text = if (t.done)
                try std.fmt.allocPrint(ctx.arena, "{s}{s}{s}", .{ th.dim, t.text, th.reset })
            else
                t.text;
            if (scope.len > 0) {
                try b.printf("{s} {s}{d}{s}  {s}  {s}({s}){s}{s}\n", .{ mark, th.dim, t.id, th.reset, text, th.dim, scope, th.reset, due_note });
            } else {
                try b.printf("{s} {s}{d}{s}  {s}{s}\n", .{ mark, th.dim, t.id, th.reset, text, due_note });
            }
            count += 1;
        }
        if (count == 0) try b.append("no todos yet — add one with `jog todo add \"…\"`\n");
    } else if (eql(sub, "done") or eql(sub, "rm")) {
        if (rest.len < 2) {
            try b.printf("usage: jog todo {s} <id>\n", .{sub});
        } else {
            const id = std.fmt.parseInt(u32, rest[1], 10) catch {
                try b.printf("invalid id '{s}'\n", .{rest[1]});
                try writeOut(ctx.io, b.items());
                return;
            };
            const ok = if (eql(sub, "done"))
                try todo.setDone(ctx.arena, ctx.io, ctx.paths.dir, ctx.paths.todos_file, id)
            else
                try todo.remove(ctx.arena, ctx.io, ctx.paths.dir, ctx.paths.todos_file, id);
            if (ok) {
                try b.printf("todo [{d}] {s}\n", .{ id, if (eql(sub, "done")) "done" else "removed" });
            } else {
                try b.printf("no todo with id {d}\n", .{id});
            }
        }
    } else {
        try b.printf("unknown todo subcommand '{s}'\n", .{sub});
    }

    try writeOut(ctx.io, b.items());
}

/// `jog remind <when> <text…>` or `jog remind <text…> <when>` — a friendly
/// front door for a dated todo. The date can be first or last; --on/--repo work too.
fn cmdRemind(ctx: *Context, rest: []const [:0]const u8) !void {
    var b: Buf = .init(ctx.arena);

    var repo: []const u8 = "";
    var due: []const u8 = "";
    var toks: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (eql(rest[i], "--repo") and i + 1 < rest.len) {
            repo = try resolveRepoArg(ctx, rest[i + 1]);
            i += 1;
        } else if ((eql(rest[i], "--on") or eql(rest[i], "--in") or eql(rest[i], "--due")) and i + 1 < rest.len) {
            if (todo_when.parse(ctx.arena, ctx.io, rest[i + 1])) |d| due = d;
            i += 1;
        } else {
            try toks.append(ctx.arena, rest[i]);
        }
    }

    var text_toks: []const []const u8 = toks.items;
    if (due.len == 0 and toks.items.len >= 2) {
        // Try the first token as the date, else the last.
        if (todo_when.parse(ctx.arena, ctx.io, toks.items[0])) |d| {
            due = d;
            text_toks = toks.items[1..];
        } else if (todo_when.parse(ctx.arena, ctx.io, toks.items[toks.items.len - 1])) |d| {
            due = d;
            text_toks = toks.items[0 .. toks.items.len - 1];
        }
    }

    if (due.len == 0 or text_toks.len == 0) {
        try b.append("usage: jog remind <when> <text>   e.g. jog remind tomorrow \"push the release\"\n");
        try b.append("  when: today · tomorrow · mon…sun · 3d · 2w · 1m · 2026-07-20\n");
        try writeOut(ctx.io, b.items());
        return;
    }

    const text = try std.mem.join(ctx.arena, " ", text_toks);
    const id = try todo.add(ctx.arena, ctx.io, ctx.paths.dir, ctx.paths.todos_file, repo, text, due);
    try b.printf("added todo [{d}] — due {s} ({s})\n", .{ id, due, todo_when.describe(ctx.arena, dt.today(ctx.arena, ctx.io), due) });
    try writeOut(ctx.io, b.items());
}

/// Starter script written by `jog plugin new`. `{s}` is the plugin name.
const plugin_skeleton =
    \\#!/bin/sh
    \\# jog plugin: {s}. Edit this, then run `jog` and your items appear.
    \\#
    \\# Print the jog JSON contract on stdout — an array of items (only "title"
    \\# is required): [{{"kind":"…","title":"…","url":"…","status":"…","note":"…"}}]
    \\#
    \\# Env available to you: JOG_REPOS (newline-separated paths), JOG_SINCE_DAYS,
    \\# JOG_TODAY, plus anything in ~/.config/jog/env (URLs, tokens, …).
    \\# Always exit 0 and print at least [] so jog never breaks.
    \\
    \\command -v jq >/dev/null 2>&1 || {{ echo "[]"; exit 0; }}
    \\
    \\# --- replace this demo with your integration ---
    \\jq -n -c '[{{ kind: "note", title: "hello from the {s} plugin — edit me!" }}]'
    \\
;

fn cmdPlugin(ctx: *Context, rest: []const [:0]const u8) !void {
    var b: Buf = .init(ctx.arena);
    const sub: []const u8 = if (rest.len >= 1) rest[0] else "list";

    if (eql(sub, "list")) {
        const plugins = ctx.cfg.plugins();
        if (plugins.len == 0) {
            try b.append("no plugins registered.\n");
            try b.append("add one:   jog plugin add <name> <command>\n");
            try b.append("or scaffold: jog plugin new <name>\n");
        } else {
            try b.printf("registered plugins ({d}):\n", .{plugins.len});
            for (plugins) |p| try b.printf("  {s} = {s}\n", .{ p.name, p.command });
        }
    } else if (eql(sub, "new")) {
        // Parse an optional name and an optional `--ai <description>`. The name is
        // the first non-flag token; if omitted (e.g. `jog plugin new --ai …`) it is
        // derived from the description.
        var name_opt: ?[]const u8 = null;
        var desc: []const u8 = "";
        var i: usize = 1;
        while (i < rest.len) : (i += 1) {
            if (eql(rest[i], "--ai")) {
                if (i + 1 < rest.len) desc = try std.mem.join(ctx.arena, " ", rest[i + 1 ..]);
                break;
            } else if (!std.mem.startsWith(u8, rest[i], "-") and name_opt == null) {
                name_opt = rest[i];
            }
        }

        const name = name_opt orelse (if (desc.len > 0) slugify(ctx.arena, desc) else "");
        if (name.len == 0) {
            try b.append("usage: jog plugin new <name> [--ai \"<what it should show>\"]\n");
            try b.append("   or: jog plugin new --ai \"<what it should show>\"   (name auto-derived)\n");
            try writeOut(ctx.io, b.items());
            return;
        }

        const dest = try std.fs.path.join(ctx.arena, &.{ ctx.paths.plugins_dir, try std.fmt.allocPrint(ctx.arena, "jog-{s}", .{name}) });
        if (std.Io.Dir.cwd().access(ctx.io, dest, .{})) |_| {
            try b.printf("plugin '{s}' already exists at {s}\n", .{ name, dest });
        } else |_| {
            var ai_made = false;
            var body: []const u8 = undefined;
            if (desc.len > 0 and ai.available(ctx)) {
                if (ai.generatePlugin(ctx, name, desc)) |script| {
                    body = script;
                    ai_made = true;
                } else {
                    try b.append("AI couldn't generate it — writing a plain skeleton instead.\n");
                    body = try std.fmt.allocPrint(ctx.arena, plugin_skeleton, .{ name, name });
                }
            } else {
                if (desc.len > 0) try b.append("no AI command configured — writing a plain skeleton instead.\n");
                body = try std.fmt.allocPrint(ctx.arena, plugin_skeleton, .{ name, name });
            }
            try std.Io.Dir.cwd().createDirPath(ctx.io, ctx.paths.plugins_dir);
            try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = dest, .data = body });
            const key = try std.fmt.allocPrint(ctx.arena, "plugin.{s}", .{name});
            const cmd = try std.fmt.allocPrint(ctx.arena, "sh '{s}'", .{dest});
            try config_mod.setKey(ctx.arena, ctx.io, ctx.paths.dir, ctx.paths.config_file, key, cmd);
            try b.printf("created plugin '{s}' and registered it.\n", .{name});
            if (ai_made) {
                try b.printf("  \x1b[2m⚠ AI-generated — review before trusting: jog plugin edit {s}\x1b[0m\n", .{name});
            }
            try b.printf("  edit:  $EDITOR {s}\n", .{dest});
            try b.printf("  test:  jog plugin run {s}\n", .{name});
        }
    } else if (eql(sub, "edit")) {
        if (rest.len < 2) {
            try b.append("usage: jog plugin edit <name>\n");
        } else {
            var found: ?[]const u8 = null;
            for (ctx.cfg.plugins()) |p| {
                if (eql(p.name, rest[1])) found = p.command;
            }
            if (found) |command| {
                // Extract the script path from `sh '<path>'` when possible.
                const path = extractPath(command) orelse command;
                try b.printf("{s}\n", .{path});
                try b.printf("open with: $EDITOR {s}\n", .{path});
            } else {
                try b.printf("no plugin named '{s}' (see `jog plugin list`)\n", .{rest[1]});
            }
        }
    } else if (eql(sub, "add")) {
        if (rest.len < 3) {
            try b.append("usage: jog plugin add <name> <command>\n");
        } else {
            const name = rest[1];
            var command: std.ArrayList(u8) = .empty;
            for (rest[2..], 0..) |tok, i| {
                if (i != 0) try command.append(ctx.arena, ' ');
                try command.appendSlice(ctx.arena, tok);
            }
            const key = try std.fmt.allocPrint(ctx.arena, "plugin.{s}", .{name});
            try config_mod.setKey(ctx.arena, ctx.io, ctx.paths.dir, ctx.paths.config_file, key, command.items);
            try b.printf("registered plugin '{s}'\n", .{name});
        }
    } else if (eql(sub, "rm")) {
        if (rest.len < 2) {
            try b.append("usage: jog plugin rm <name>\n");
        } else {
            const key = try std.fmt.allocPrint(ctx.arena, "plugin.{s}", .{rest[1]});
            const ok = try config_mod.removeKey(ctx.arena, ctx.io, ctx.paths.dir, ctx.paths.config_file, key);
            try b.printf("{s} plugin '{s}'\n", .{ if (ok) "removed" else "no such", rest[1] });
        }
    } else if (eql(sub, "run")) {
        if (rest.len < 2) {
            try b.append("usage: jog plugin run <name>\n");
        } else {
            const name = rest[1];
            var command: ?[]const u8 = null;
            for (ctx.cfg.plugins()) |p| {
                if (eql(p.name, name)) command = p.command;
            }
            if (command) |cmd| {
                const roots = ctx.cfg.roots(ctx.env);
                const depth = ctx.cfg.getInt("depth", 3);
                const repos = discover_mod.discover(ctx.arena, ctx.io, ctx.env, roots, depth);
                const res = plugin.run(ctx.arena, ctx.io, ctx.env, cmd, .{
                    .repos = repos,
                    .days = ctx.cfg.getInt("days", 7),
                    .today = dt.today(ctx.arena, ctx.io),
                }, ctx.paths.env_file);
                if (res.err) |e| {
                    try b.printf("plugin '{s}' error: {s}\n", .{ name, e });
                } else {
                    try b.printf("plugin '{s}' returned {d} item(s):\n", .{ name, res.items.len });
                    for (res.items) |it| {
                        try b.printf("  • {s}", .{it.title});
                        if (it.status.len > 0) try b.printf("  [{s}]", .{it.status});
                        try b.append("\n");
                        if (it.url.len > 0) try b.printf("    {s}\n", .{it.url});
                    }
                }
            } else {
                try b.printf("no plugin named '{s}' (see `jog plugin list`)\n", .{name});
            }
        }
    } else {
        try b.printf("unknown plugin subcommand '{s}'\n", .{sub});
    }

    try writeOut(ctx.io, b.items());
}

fn cmdShellInit(ctx: *Context, rest: []const [:0]const u8) !void {
    const which: []const u8 = if (rest.len >= 1) rest[0] else "";
    if (shell.hookFor(which)) |hook| {
        try writeOut(ctx.io, hook);
    } else {
        var b: Buf = .init(ctx.arena);
        try b.append("usage: jog shell-init <zsh|bash>\n");
        try writeOut(ctx.io, b.items());
    }
}

/// Called by the shell hook on directory change. Prints the repo briefing only on
/// the first visit each day; silent otherwise. Never fails loudly (it's in your
/// prompt), so errors are swallowed.
fn cmdEntered(ctx: *Context, rest: []const [:0]const u8) !void {
    if (rest.len < 1) return;
    const path = rest[0];

    // Must be inside a git repo; otherwise stay silent.
    const repo = git.run(ctx.arena, ctx.io, path, &.{ "rev-parse", "--show-toplevel" }) orelse return;
    if (repo.len == 0) return;

    const today = dt.today(ctx.arena, ctx.io);
    if (seen.briefedToday(ctx.arena, ctx.io, ctx.paths.seen_file, repo, today)) return;

    const out = briefing.renderRepo(ctx, repo) catch return;
    writeOut(ctx.io, out) catch return;
    seen.mark(ctx.arena, ctx.io, ctx.paths.dir, ctx.paths.seen_file, repo, today) catch {};
}

/// Resolve a `--repo` argument: "." becomes the current repo's toplevel.
fn resolveRepoArg(ctx: *Context, val: []const u8) ![]const u8 {
    if (!eql(val, ".")) return val;
    if (git.run(ctx.arena, ctx.io, ".", &.{ "rev-parse", "--show-toplevel" })) |top| {
        if (top.len > 0) return top;
    }
    return ".";
}

fn cmdConfig(ctx: *Context) !void {
    var b: Buf = .init(ctx.arena);
    try b.printf("config file: {s}{s}\n\n", .{
        ctx.paths.config_file,
        if (ctx.cfg.loaded_from_file) "" else "  (not present - using defaults)",
    });

    const roots = ctx.cfg.roots(ctx.env);
    try b.append("roots       = ");
    for (roots, 0..) |r, i| {
        if (i != 0) try b.append(", ");
        try b.append(r);
    }
    try b.append("\n");

    try b.printf("depth       = {d}\n", .{ctx.cfg.getInt("depth", 3)});
    try b.printf("days        = {d}\n", .{ctx.cfg.getInt("days", 7)});
    try b.printf("ai_enabled  = {s}\n", .{boolStr(ctx.cfg.getBool("ai_enabled", true))});
    try b.printf("ai_command  = {s}\n", .{ctx.cfg.getOr("ai_command", "claude -p")});
    try b.printf("hints       = {s}\n", .{boolStr(ctx.cfg.getBool("hints", true))});

    try b.append("sections    = ");
    if (ctx.cfg.getList("sections")) |secs| {
        for (secs, 0..) |s, i| {
            if (i != 0) try b.append(", ");
            try b.append(s);
        }
    } else {
        try b.append("(default: git, todos, + registered plugins)");
    }
    try b.append("\n");

    const plugins = ctx.cfg.plugins();
    try b.printf("\nplugins ({d}):\n", .{plugins.len});
    if (plugins.len == 0) {
        try b.append("  (none registered)\n");
    } else {
        for (plugins) |p| try b.printf("  {s} = {s}\n", .{ p.name, p.command });
    }

    try writeOut(ctx.io, b.items());
}

fn cmdInit(ctx: *Context) !void {
    var b: Buf = .init(ctx.arena);
    if (ctx.cfg.loaded_from_file) {
        try b.printf("config already exists at {s}\n", .{ctx.paths.config_file});
    } else {
        try config_mod.writeDefault(ctx.io, ctx.paths.dir, ctx.paths.config_file);
        try b.printf("wrote default config to {s}\n", .{ctx.paths.config_file});
    }

    const report = bootstrap.install(ctx);
    try b.printf("installed {d} bundled plugin script(s) in {s}\n", .{ report.installed, ctx.paths.plugins_dir });
    // Prefer the just-detected command; otherwise report whatever is configured.
    const ai_cmd = report.ai_command orelse ctx.cfg.getOr("ai_command", "");
    if (ai_cmd.len > 0) {
        try b.printf("AI brief via: {s}\n", .{ai_cmd});
    } else {
        try b.append("no AI command detected — set `ai_command` in config to enable the AI brief\n");
    }

    if (report.registered.items.len > 0) {
        try b.append("registered (dependency present): ");
        for (report.registered.items, 0..) |n, i| {
            if (i != 0) try b.append(", ");
            try b.append(n);
        }
        try b.append("\n");
    }
    if (report.skipped.items.len > 0) {
        try b.append("installed but inactive (missing tool or credentials): ");
        for (report.skipped.items, 0..) |n, i| {
            if (i != 0) try b.append(", ");
            try b.append(n);
        }
        try b.append("\n  add the needed creds to ~/.config/jog/env, then re-run `jog init`\n");
    }
    try writeOut(ctx.io, b.items());
}

fn cmdScan(ctx: *Context) !void {
    const roots = ctx.cfg.roots(ctx.env);
    const depth = ctx.cfg.getInt("depth", 3);
    const repos = discover_mod.discover(ctx.arena, ctx.io, ctx.env, roots, depth);

    var b: Buf = .init(ctx.arena);
    try b.printf("discovered {d} repo(s) under depth {d}:\n", .{ repos.len, depth });
    const days = ctx.cfg.getInt("days", 7);
    for (repos) |repo| {
        const f = git.facts(ctx.arena, ctx.io, repo, days, 1);
        const flag = if (f.hasActivity()) "*" else " ";
        try b.printf("  {s} {s}  ({s})\n", .{ flag, repo, if (f.branch.len > 0) f.branch else "?" });
    }
    try b.printf("\n  * = recent activity in the last {d} day(s)\n", .{days});
    try writeOut(ctx.io, b.items());
}

fn boolStr(v: bool) []const u8 {
    return if (v) "true" else "false";
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
