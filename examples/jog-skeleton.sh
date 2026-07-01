#!/bin/sh
# Skeleton for a custom jog plugin. Copy, adapt, then register:
#   jog plugin add myplugin "sh /absolute/path/to/jog-myplugin.sh"
#
# A plugin just prints the jog JSON contract on stdout — an array of items:
#   [{"kind":"...","title":"...","url":"...","status":"...","note":"...","updated":"..."}]
# Only "title" is required; the rest are optional.
#
# jog runs your plugin with these environment variables available:
#   JOG_REPOS        newline-separated list of discovered repo paths
#   JOG_SINCE_DAYS   the lookback window (integer days)
#   JOG_TODAY        today's date (YYYY-MM-DD)
# Plus anything you put in ~/.config/jog/env (URLs, tokens, etc).
#
# Always exit 0 and print at least [] so a missing dependency never breaks jog.

command -v jq >/dev/null 2>&1 || { echo "[]"; exit 0; }

# Example: turn each repo path into a trivial item.
printf '%s\n' "$JOG_REPOS" | jq -R -s -c '
  [ split("\n")[] | select(length > 0) | { kind: "repo", title: . } ]
'
