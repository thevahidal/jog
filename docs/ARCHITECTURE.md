# jog architecture

A tiny Zig core that is a **generic host**: it gathers facts, runs plugins, and
(optionally) pipes a compact context to an AI command. No integration-specific
code is compiled in — GitHub, Jira and Odoo are all plugins.

## Source layout (`src/`)

| File | Responsibility |
|---|---|
| `main.zig` | CLI parsing and command dispatch; the `Context` is built here. |
| `app.zig` | Shared `Context`, the `Buf` string builder, stdout/stderr helpers (incl. tty-aware progress notes). |
| `paths.zig` | Resolves `~/.config/jog/*` locations (XDG-aware). |
| `config.zig` | Flat `key = value` store with typed getters, defaults, and `setKey`/`removeKey`. Zero-config when no file exists. |
| `discover.zig` | Walks `roots` to depth, finds git repos (skips ignored dirs). |
| `git.zig` | Runs `git` and parses per-repo facts (branch, commits, dirty, unpushed, stash). |
| `todo.zig` | `todos.tsv` CRUD, including the optional `due` date column. |
| `when.zig` | Human-friendly date parsing (`tomorrow`, `fri`, `3d`, `2026-07-20`) and relative descriptions. |
| `seen.zig` | Per-repo "last briefed today" gate for the shell hook. |
| `dismiss.zig` | Dismissed-pattern store + matcher; persists the numbered "last items" list. |
| `plugin.zig` | Runs a plugin via `sh -c`, injects env (`JOG_*` + `~/.config/jog/env`), parses the JSON contract. |
| `briefing.zig` | Composes ordered sections into the human view **and** the compact AI context in one pass. The `Picker` numbers dismissable items. |
| `ai.zig` | Streams the AI summary (stdout inherit + `tee` capture), the brief TTL cache, and `ask`. |
| `bootstrap.zig` | First-run setup: installs bundled plugin scripts, auto-registers available ones, detects an AI command, writes `env.example`. |
| `shell.zig` | Emits the zsh/bash hook for `jog shell-init`. |
| `dt.zig` | Minimal UTC date helpers. |

Bundled plugin scripts live in `plugins/` and are embedded into the binary via
anonymous imports declared in `build.zig`, so the installed binary is
self-contained.

## Request flow (a `jog` run)

1. `main` builds `Context` (arena, io, env map, paths, config).
2. First run only: `bootstrap.install` writes plugins, registers available ones,
   picks an AI command.
3. `cmdBrief`: if a fresh cached brief exists → print it and stop.
4. Otherwise `briefing.renderGlobal` discovers repos, gathers git facts, runs
   plugins (showing progress), and builds both the human view and the AI context,
   applying dismiss filters.
5. If AI is on, `ai.summarizeStream` pipes the context to `ai_command`, streams the
   reply live, and caches the full brief. Otherwise the deterministic view prints.

## Zig 0.16 notes

- `main(init: std.process.Init)`; an `Io` instance is threaded through everything.
- Filesystem via `std.Io.Dir`/`std.Io.File`; subprocesses via `std.process.run`
  and `std.process.spawn` (streaming uses `stdout = .inherit`).
- `std.ArrayList` is unmanaged (`.empty` + pass the allocator).
- Time via `std.Io.Clock.now(.real, io)`.
- Bundled scripts are embedded with `@embedFile` of build-registered import names.
