# Writing jog plugins

A plugin teaches jog about a new source of work — a tracker, an ERP, a queue,
anything. The core knows nothing about your integration; it just runs a command
and merges what it prints. That means a plugin can be written in **any language**,
as long as it prints the JSON contract on stdout.

## The contract

A plugin prints a **JSON array of items** on stdout:

```json
[
  {
    "kind": "pr",
    "title": "Fix flaky login test",
    "url": "https://github.com/acme/api/pull/42",
    "status": "review-requested",
    "note": "CI failing",
    "updated": "2026-06-27"
  }
]
```

| Field | Required | Meaning |
|---|---|---|
| `title` | ✅ | The headline shown in the briefing. |
| `kind` | | Category (`pr`, `issue`, `ticket`, `activity`, `commit`, …). |
| `url` | | Link to the item. |
| `status` | | Short state, shown in brackets, e.g. `[review-requested]`. |
| `note` | | Extra context shown under the title. |
| `updated` | | Date string (free-form). |

Unknown fields are ignored. Always **print at least `[]` and exit 0**, even on
error, so a missing dependency or network blip never breaks jog.

## What jog passes you

When jog runs a plugin it sets these environment variables:

| Variable | Value |
|---|---|
| `JOG_REPOS` | newline-separated list of discovered repo paths |
| `JOG_SINCE_DAYS` | the lookback window (integer days) |
| `JOG_TODAY` | today's date, `YYYY-MM-DD` |

Plus everything in your personal env file `~/.config/jog/env` (URLs, tokens, …).
That file is the right place for per-user/secret values — it's injected into the
plugin's environment and never lives in the repo.

In a **per-repo** brief (`jog .`), jog runs plugins with `JOG_REPOS` set to just
that repo, and additionally keeps only items whose `title`/`note`/`url` mention the
repo name — so a single-repo brief stays focused.

## The fastest way: `jog plugin new`

```sh
jog plugin new linear        # scaffolds ~/.config/jog/plugins/jog-linear and registers it
$EDITOR ~/.config/jog/plugins/jog-linear   # (jog plugin edit linear prints the path)
jog plugin run linear        # test it — prints the parsed items
jog                          # it now appears in your brief
```

`jog plugin new` writes a working starter script (it already prints valid JSON),
registers it, and shows you the path. Replace the demo line with your integration.

### Let AI write it

```sh
jog plugin new gitlab-blocked --ai "my GitLab merge requests that are blocked"
```

With `--ai "<description>"`, jog asks your configured AI to write the whole plugin
script from your description, then registers it. **Always review AI-generated code
before trusting it** (`jog plugin edit <name>`) — jog flags it and reminds you.

## Registering an existing script

```sh
jog plugin add <name> "<command>"   # e.g. sh /abs/path/to/jog-linear.sh
jog plugin list
jog plugin run <name>               # debug: prints parsed items
jog plugin edit <name>              # print the script path
jog plugin rm <name>
```

A plugin command is run via `sh -c`, so pipes and quoting work. Then add the name
to your `sections` (or leave it — unset `sections` shows todos, git, and all
registered plugins).

## Performance notes

- Plugins run only in the **global** `jog brief` and in `jog .`, never in the
  per-repo shell pop-up (which stays instant).
- Keep output bounded; jog caps what it displays (`<name>.max`) but parses
  everything. For expensive scans, cap inside the script.
- The whole brief is cached (`cache_ttl`), so a plugin isn't re-run on every
  invocation.

## Minimal example

```sh
#!/bin/sh
command -v jq >/dev/null 2>&1 || { echo "[]"; exit 0; }
printf '%s\n' "$JOG_REPOS" | jq -R -s -c '
  [ split("\n")[] | select(length > 0) | { kind:"repo", title:. } ]'
```

See [../examples/jog-skeleton.sh](../examples/jog-skeleton.sh).

---

## Bundled plugins

These ship with jog (embedded in the binary, installed to `~/.config/jog/plugins/`
on first run) and auto-register when their dependency is present.

### git-based (zero setup): `standup`, `loose-ends`, `code-todos`
Pure `git`/`git grep` over `JOG_REPOS`. They light up on any machine.

### `docker` — needs `docker` + `jq`
Your running containers, so you remember what's up locally. Auto-registers when
the `docker` CLI is installed; prints nothing when the daemon is down.

### `gitlab` — needs `curl` + `jq` + a token
Merge requests and issues assigned to you, on GitLab.com or self-hosted. Config in
`~/.config/jog/env`: `GITLAB_TOKEN` (scope `read_api`), optional `GITLAB_URL`
(self-hosted) and `GITLAB_USER` (to also include MRs where you're a reviewer).

### `linear` — needs `curl` + `jq` + an API key
Your active (non-done) Linear issues. Config: `LINEAR_API_KEY` (Linear → Settings
→ Security & access → Personal API keys).

### `calendar` — needs `curl` + `jq` + an ICS URL
Your meetings today from any iCalendar feed. Config: `JOG_CALENDAR_URL` — Google
Calendar's "secret address in iCal format", or Outlook's published-calendar ICS.
Handles one-off events plus simple daily and weekly-by-day recurrences (standups,
1:1s); monthly/yearly recurrences aren't expanded.

### `pagerduty` — needs `curl` + `jq` + a token
Open incidents (triggered/acknowledged). Config: `PAGERDUTY_TOKEN`, and optional
`PAGERDUTY_USER_ID` to show only incidents assigned to you.

### `github` — needs `gh` (authenticated) + `jq`
Wraps the GitHub CLI to emit review-requested PRs, your open PRs, and assigned
issues. Auto-registers when `gh auth status` succeeds.

### `jira` — needs `curl` + `jq` + credentials
Generic for any Jira Cloud instance. Configure in `~/.config/jog/env`:

```ini
JIRA_URL=https://your-org.atlassian.net
JIRA_EMAIL=you@example.com
JIRA_TOKEN=...            # https://id.atlassian.com/manage/api-tokens
# JIRA_JQL=...            # optional, overrides the default "assigned & not done"
# JIRA_MAX=20
```

It queries `assignee = currentUser() AND statusCategory != Done` via the Jira
Cloud search API and emits one `ticket` item per issue (title = summary, url =
`/browse/KEY`, status = workflow status). Auto-registers once `JIRA_URL` **and**
`JIRA_TOKEN` are set; re-run `jog init` after adding them.

### `odoo` — needs `curl` + `jq` + credentials
Generic for any Odoo instance, via its JSON-RPC API. Configure in
`~/.config/jog/env`:

```ini
ODOO_URL=https://erp.example.com
ODOO_DB=your-database
ODOO_USER=you@example.com
ODOO_PASSWORD=...         # password or API key
# ODOO_MAX=20
```

It authenticates (`common.authenticate` → uid), then `search_read`s the
`mail.activity` records assigned to you and emits one `activity` item each
(title = summary or activity type, note = the record's name, status = due date).
Auto-registers once `ODOO_URL` **and** `ODOO_PASSWORD` are set; re-run `jog init`.

> Tip: get your Odoo database name from the login page dropdown, or the
> `/web/database/selector` page. API keys live under *Preferences → Account
> Security → API Keys* (when enabled by your admin).

---

## Sharing a plugin with your team

Because a plugin is just a script + some env vars:

- **Generic** logic (the script) → commit it to the repo's `plugins/` (to bundle)
  or share the file. It should read all instance-specific values from env.
- **Personal** values (URLs, accounts, tokens) → each person puts their own in
  `~/.config/jog/env`. Nothing secret or user-specific goes in the script.

This is exactly how the bundled `jira` and `odoo` plugins are built: one generic
script for everyone, per-user config kept private.
