# jog

**Jog your memory at the start of the day.** `jog` is a small, fast, zero-config
CLI (written in Zig) that reminds you where you left off across all your work —
git activity, todos, day-scheduled reminders, GitHub PRs, Jira issues, Odoo
activities — and summarizes it into a short AI brief. It can also pop that briefing
up automatically the first time you `cd` into a repo each day.

It does a lot out of the box, and gets more powerful as you make it yours.

```
◆ jog — your brief

- Focus on the api service: 23 uncommitted changes and an unpushed branch.
- 4 PRs are waiting on your review — start with the failing-CI one.
- Ticket PROJ-123 is still in progress; 2 calendar events today.
- Loose ends: commit/push the web repo before it drifts further.

(add --full for details · jog ask "…" to dig in)
```

- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Commands](#commands)
- [Configuration](#configuration)
- [AI](#ai)
- [Plugins & integrations](#plugins--integrations)
- [Privacy](#privacy)
- [Design](#design)
- [Troubleshooting](#troubleshooting)

---

## Install

**macOS / Linux** — one line (downloads the right prebuilt binary):

```sh
curl -fsSL https://raw.githubusercontent.com/thevahidal/jog/master/install.sh | sh
```

**Windows** — run jog inside **WSL** or **Git Bash** and use the line above
(recommended — jog uses a POSIX `sh` for git and plugins). A native binary is also
available:

```powershell
irm https://raw.githubusercontent.com/thevahidal/jog/master/install.ps1 | iex
```

**From source** — requires [Zig 0.16](https://ziglang.org/):

```sh
git clone https://github.com/thevahidal/jog && cd jog
zig build -Doptimize=ReleaseSafe
cp zig-out/bin/jog ~/.local/bin/          # or anywhere on your PATH
```

Then just run:

```sh
jog                               # that's it — no config needed
```

On the first run jog discovers your repos, installs the bundled plugins, and
auto-enables the ones whose tools you already have (git, plus GitHub if `gh` is
authenticated). It also auto-detects a working AI command (`claude`, then
`gemini`, else a local `ollama` model) for the summary.

Make it ambient — add to `~/.zshrc` (or `~/.bashrc`):

```sh
eval "$(jog shell-init zsh)"      # or: jog shell-init bash
```

Now the first time you `cd` into a repo each day, jog quietly shows that repo's
briefing (git + todos), then stays silent.

---

## How it works

The core is tiny and does only core things: discover git repos, read their state,
track todos, run the once-a-day shell pop-up, run plugins, and (optionally) pipe a
compact context to an AI command. **Everything else is a plugin** — even GitHub,
Jira and Odoo. See [docs/PLUGINS.md](docs/PLUGINS.md).

### Two kinds of brief

- **`jog`** — a global brief across all your repos, AI-summarized by default.
- **`jog .`** (or `jog <path>`) — a context-aware brief for a single repo: its git
  state, its todos, and only the PRs/issues/code-todos that belong to it.

### Todos & reminders

There's one concept: a **todo**. Give it a **date** and it becomes a reminder that
jog surfaces on the day — dated todos sort to the top of your list, most urgent
first, marked **⚠ overdue**, **● today**, **○ upcoming**.

```sh
jog todo add "refactor the parser"                 # a plain todo
jog todo add "review the RFC" --due mon --repo .   # dated + repo-scoped
jog remind tomorrow "cut the release"              # shortcut for a dated todo
jog remind fri "sprint demo prep"
```

Dates are natural: `today`, `tomorrow`, weekday names (`mon`…`sun`), `3d`, `2w`,
`1m`, or an absolute `YYYY-MM-DD` — and `jog remind` accepts the date first or
last. Reschedule with `jog todo snooze <id> <when>`, complete with
`jog todo done <id>`. `jog remind` is pure sugar for `jog todo add … --due`.

### Speed

The AI brief is **streamed** live as the model writes it, and **cached** so repeat
runs are instant — jog only re-thinks when the cache expires (`cache_ttl`, default
15 min) or you pass `--refresh`. While gathering, it shows transient progress.

---

## Commands

```
jog                       Show the briefing (AI-summarized by default)
jog brief --full          Full deterministic briefing (no AI), alias --no-ai
jog brief --ai            Force the AI summary
jog brief <section…>      Only these sections, e.g. `jog brief github git`
jog brief --days <n>      Override the lookback window for this run
jog brief --refresh       Rebuild now (bypass the cached brief)
jog brief -n / --numbers  Numbered view (each item gets a number for `dismiss`)
jog brief --repo <path>   Deterministic single-repo view

jog .                     Context-aware AI brief for the repo you're in
jog <path>                Context-aware AI brief for a repo at <path>

jog ask "<question>"      Ask AI about your current work (streamed)
jog tidy                  AI review of your todos (merge/drop/rephrase)

jog dismiss               Show a numbered list of items you can hide
jog dismiss <number>      Hide the numbered item
jog dismiss "<text>"      Hide anything matching <text>
jog dismiss --list        Show dismissed patterns
jog dismiss --clear       Undo all dismissals

jog todo add <text>       Add a todo (--repo . to scope; --due <when> to date it)
jog remind <when> <text>  Shortcut for a dated todo — e.g. jog remind fri "demo"
jog todo list [--all]     List todos (dated ones show their day)
jog todo done <id>        Mark a todo done
jog todo snooze <id> <when>  Move a todo's due date
jog todo rm <id>          Remove a todo

jog plugin new <n>        Scaffold a plugin (--ai "<desc>" to have AI write it)
jog plugin list           List registered plugins
jog plugin add <n> <cmd>  Register an existing command as a plugin
jog plugin edit <n>       Show a plugin's script path
jog plugin rm <n>         Unregister a plugin
jog plugin run <n>        Run a plugin and print its parsed items (debug)

jog scan                  List auto-discovered git repos
jog config                Print effective config (and its path)
jog init                  Write a commented config + install bundled plugins
jog shell-init zsh|bash   Print the shell hook
jog help                  Show help
```

---

## Configuration

Everything is optional — jog works with no config file. Settings live at
`~/.config/jog/config` (or `$XDG_CONFIG_HOME/jog/config`). Run `jog init` to drop a
commented template. Format is `key = value`, one per line.

```ini
roots = ~/dev                 # where to look for repos (comma-separated)
depth = 3                     # how deep to search under each root
days = 7                      # "recent" window

# Compose your briefing — which sections show, and in what order.
# Built-ins: todos, git. Plus any registered plugin name.
sections = todos, git, standup, loose-ends, github, jira, odoo, code-todos

git.show = branch, commits, dirty, unpushed, stash
git.max_commits = 5
todos.max = 10
github.max = 10               # any <plugin>.max caps that section

ai_enabled = true             # set false to always show the full briefing
ai_command = claude -p        # any CLI that reads a prompt on stdin
cache_ttl = 900               # seconds to reuse a brief before rebuilding (0 = off)

hints = true                  # one-line tips at the end of the briefing

plugin.github = sh '~/.config/jog/plugins/jog-github'   # name = command
```

| File (in `~/.config/jog/`) | Purpose |
|---|---|
| `config` | Settings above. Plain text, hand-editable. |
| `env` | **Personal** URLs/tokens injected into plugins. Keep private (`chmod 600`). |
| `plugins/` | Installed plugin scripts (bundled + yours). |
| `todos.tsv` | Your todos. |
| `seen.tsv` | Per-repo "last briefed today" state for the shell hook. |
| `dismissed` | Patterns you've hidden. |
| `brief_cache` / `ai_cache` | Cached AI output. |

---

## AI

By default jog summarizes the briefing into a short, prioritized brief using a
**local AI CLI**, streamed live. jog never stores API keys or calls an API
directly — it pipes a compact context to whatever command you set as `ai_command`.

- **Auto-detected** on first run: `claude -p`, then `gemini -p`, else `ollama run
  <model>`. Any command that reads a prompt on stdin works (set `ai_command`
  yourself for others, e.g. `codex exec`).
- **Falls back** to the full deterministic briefing if AI is unavailable or fails.
- **`jog ask "…"`** answers free-form questions using your live work context.
- **`jog tidy`** has the AI review your todos — merge duplicates, drop stale ones,
  suggest clearer wording, and tell you what to do first (advisory; it never edits
  your todos).
- Override per run with `--full` (no AI), `--ai` (force), `--refresh` (rebuild).

To switch models, set `ai_command` in config, e.g. `ai_command = ollama run qwen2.5`.

---

## Plugins & integrations

A plugin is any executable that prints the jog **JSON contract** on stdout. jog
runs registered plugins and merges their items into the briefing. The core knows
nothing about what they integrate. Full guide: **[docs/PLUGINS.md](docs/PLUGINS.md)**.

**Bundled** (installed on first run, auto-enabled when their dependency is present):

| Plugin | Needs | Shows |
|---|---|---|
| `standup` | git | your recent commits across repos |
| `loose-ends` | git | repos with uncommitted/unpushed/stashed work |
| `code-todos` | git grep | `TODO`/`FIXME`/`XXX` in your code |
| `docker` | `docker` + `jq` | your running containers (local context) |
| `github` | `gh` (authed) + `jq` | review-requested PRs, your PRs, assigned issues |
| `gitlab` | `curl` + `jq` + token | your assigned merge requests & issues |
| `jira` | `curl` + `jq` + creds | your open Jira issues |
| `linear` | `curl` + `jq` + API key | your active Linear issues |
| `odoo` | `curl` + `jq` + creds | your Odoo activities |
| `calendar` | `curl` + `jq` + ICS URL | your meetings today (from an iCal feed) |
| `pagerduty` | `curl` + `jq` + token | your open incidents |

`standup`, `loose-ends`, `code-todos` light up with zero setup; `docker` and
`github` auto-enable when their tool is present; the rest turn on once you add
their credentials to `~/.config/jog/env` (see below).

### Enabling Jira / Odoo

The scripts are generic; your instance details go in the **personal env file**
`~/.config/jog/env` (never in the repo). After `jog init` there's an `env.example`
to copy from. Fill in, then run `jog init` again to register:

```ini
# ~/.config/jog/env   (chmod 600)
JIRA_URL=https://your-org.atlassian.net
JIRA_EMAIL=you@example.com
JIRA_TOKEN=...                       # id.atlassian.com/manage/api-tokens

ODOO_URL=https://erp.example.com
ODOO_DB=your-db
ODOO_USER=you@example.com
ODOO_PASSWORD=...                    # password or API key
```

### Your own plugin

Write a script that prints the contract and register it:

```sh
jog plugin add linear "sh ~/scripts/jog-linear.sh"
```

See [examples/jog-skeleton.sh](examples/jog-skeleton.sh) and
[docs/PLUGINS.md](docs/PLUGINS.md).

---

## Privacy

- jog stores **no API keys**. AI runs through a command you choose; with a local
  model (ollama) your data never leaves the machine.
- Per-user secrets live only in `~/.config/jog/env` on your machine — not in the
  repo, not in `config`.
- Plugins are plain scripts you can read. Bundled ones live in
  `~/.config/jog/plugins/`.

---

## Design

- **Tiny core, generic host.** The Zig binary has no integration-specific code.
- **Everything is a composable section.** `sections` controls what shows and the
  order — git, todos and plugins are uniform.
- **Plugins are just commands** emitting a small JSON contract. Bundled ones are
  shell scripts embedded in the binary and installed on first run; yours work
  identically.
- **Graceful by default.** A missing dependency or failing plugin becomes a
  one-line note, never a crash.

Source layout: see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## Troubleshooting

- **No AI summary, just the full briefing** — no working `ai_command`. Run
  `jog init` to re-detect, or set one in config (`ollama run qwen2.5`). Check it
  reads stdin: `echo hi | <your ai_command>`.
- **A plugin shows "unavailable"** — run `jog plugin run <name>` to see why
  (missing binary, bad JSON, network/credentials).
- **Jira/Odoo show nothing** — confirm creds in `~/.config/jog/env`, then
  `jog plugin run jira` / `jog plugin run odoo`. jira/odoo register only once
  their token/password is present; re-run `jog init` after adding them.
- **Brief seems stale** — it's cached; run `jog brief --refresh` or lower
  `cache_ttl`.
- **A repo shows branch `HEAD`** — it's a detached checkout/worktree.
