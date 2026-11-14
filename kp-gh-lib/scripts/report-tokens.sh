#!/usr/bin/env bash
# Sum this Claude Code session's token usage since a start time and record it as one row
# in a marker-tagged comment on an issue or PR, so every run's cost stays visible.
#
# Usage: report-tokens.sh <start-iso> <marker> <owner/repo> <issue-or-pr>
#        report-tokens.sh --render <start-iso> <marker> <transcript.jsonl> <body-file|->
#   <start-iso>  run start, ISO-8601 UTC as `date -u +%Y-%m-%dT%H:%M:%S.000Z` prints it
#   <marker>     the skill's stable marker, e.g. "<!-- kp-fix-pr:token-usage -->"
#
# The comment holds one table, one row per run, keyed by run start: a re-run with the
# same start rewrites its own row instead of overwriting the whole comment, and a new run
# appends. A final **Sum** row totals the columns. The table is capped at 100 rows — past
# that the oldest go and the sum line says how many were dropped, which also keeps the
# body far under GitHub's 65,536-character limit. A comment still in the pre-2026-09
# single-line format is converted in place: its figures become the first row, with the
# run start, model, effort and subagents it never recorded left as `?`. A table in the
# 7-column format (no `effort`, no `subagents`) is converted the same way, its old rows
# getting `?` in both new cells.
#
# `effort` is $KP_EFFORT when it is exactly one of low, medium, high, xhigh, max, else
# `—`. `subagents` sums the four usage figures over every `agent-*.jsonl` in
# <transcript without .jsonl>/subagents/ since the run start, each message.id once per
# file; `0` when there is none. `total` is the top-level figures only — it excludes
# `subagents`, so rows stay comparable with those written before the column existed.
#
# Run from the session's working directory: the transcript is the newest *.jsonl in
# ~/.claude/projects/<$PWD with / _ . replaced by ->, else the newest one under
# ~/.claude/projects/*/. With no readable transcript the run still gets a row, its
# figures `?`, and the sum passes over it.
#
# `--render` is the offline mode the fixtures drive: it reads the named transcript and
# the existing comment body from a file (`-` when there is none), prints the new body on
# stdout, and touches no GitHub.
#
# Prints the run's own table row on stdout.
# Exit: 0 comment upserted · 1 GitHub read/write failed · 2 bad arguments.
set -euo pipefail

usage() {
  echo "usage: report-tokens.sh <start-iso> <marker> <owner/repo> <issue-or-pr>" >&2
  echo "       report-tokens.sh --render <start-iso> <marker> <transcript.jsonl> <body-file|->" >&2
  exit 2
}

START_PATTERN='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$'
# The marker is the comment's identity and lands verbatim in the body it writes.
MARKER_PATTERN='^<!-- [A-Za-z0-9_:-]+ -->$'
REPO_PATTERN='^[^/[:space:]]+/[^/[:space:]]+$'

render=0
if [ "${1:-}" = --render ]; then
  render=1
  shift
fi
[ $# -eq 4 ] || usage
start=$1
marker=$2
[[ $start =~ $START_PATTERN ]] || usage
[[ $marker =~ $MARKER_PATTERN ]] || usage
if [ "$render" -eq 1 ]; then
  transcript=$3
  existing=$4
  [ "$existing" = - ] && existing=
else
  repo_ref=$3
  number=$4
  [[ $repo_ref =~ $REPO_PATTERN ]] || usage
  [[ $number =~ ^[0-9]+$ ]] || usage
  transcript="$HOME/.claude/projects/$(printf '%s' "$PWD" | sed 's#[/_.]#-#g')"
  existing=
fi


work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

if [ "$render" -eq 1 ]; then
  python3 "$(dirname "${BASH_SOURCE[0]}")"/py/report_tokens.py "$start" "$marker" "$transcript" "" "$existing" \
    "$work/body.md" "$work/comment-id" >/dev/null
  cat "$work/body.md"
  exit 0
fi

if ! gh api --paginate "repos/$repo_ref/issues/$number/comments" > "$work/comments.json"
then
  echo "report-tokens.sh: cannot list comments on $repo_ref#$number" >&2
  exit 1
fi

row=$(python3 "$(dirname "${BASH_SOURCE[0]}")"/py/report_tokens.py "$start" "$marker" "$transcript" \
  "$work/comments.json" "" "$work/body.md" "$work/comment-id")
comment_id=$(cat "$work/comment-id")

if [ -n "$comment_id" ]; then
  request=(-X PATCH "repos/$repo_ref/issues/comments/$comment_id")
else
  request=(-X POST "repos/$repo_ref/issues/$number/comments")
fi
if ! gh api "${request[@]}" -f body="$(cat "$work/body.md")" >/dev/null; then
  echo "report-tokens.sh: cannot write the token-usage comment on $repo_ref#$number" >&2
  exit 1
fi
printf '%s\n' "$row"
