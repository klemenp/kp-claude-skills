#!/usr/bin/env bash
# Find the issues that carry a marker line — `<marker>: <value>` — outside the human-only
# fence and outside every <details> block. The kp-* skills' dedup and referrer lookups all
# need this one search; they used to describe it in prose, each slightly differently.
#
# Usage: find-marker.sh <owner/repo> <marker> <value> [--state open|closed|all]
#          [--label <name>]… [--scope repo|owner] [--comments] [--from-file <json>]
#        find-marker.sh <owner/repo> <marker> --any-value [same options]
#
# Search: REST `search/issues` (issues only, never PRs), paginated to GitHub's 1,000-result
# cap, for the quoted phrase `"<marker>: <value>"` — the quotes are load-bearing: unquoted,
# GitHub reads `<marker>:` as an unknown qualifier and returns nothing. `--scope repo`
# (default) searches `repo:<owner/repo>`; `--scope owner` searches `user:<owner>`, which
# also covers an organization's repos. `--state` defaults to `open`; each `--label` is a
# further AND filter. An issue-reference value searches both of its written forms.
# `--any-value` searches `"<marker>:"` and accepts any value on the confirmed line.
# `--comments` also searches `in:comments` and confirms against each comment body.
#
# Confirm: search is over-broad, so a hit counts only when a line of its body (or comment),
# trimmed, is exactly `<marker>: <value>`, bare or as a whole `<!-- … -->` comment (the
# form skill-output markers take) — case-sensitive — and sits outside every
# human-only fence and every <details> … </details> block (nesting counted; an unclosed
# start fences to the end). An issue reference matches both forms: `#38` matches `#38` and
# `<owner/repo>#38` in hits from <owner/repo> only; `<owner/repo>#38` matches itself and
# `#38` in a hit from that repo. `#380` never matches `#38`.
#
# Prints a JSON array, possibly empty, one entry per confirmed line:
#   [{"number": n, "repo": "owner/repo", "state": "OPEN"|"CLOSED", "labels": [names],
#     "url": "…", "value": "<value on the line>", "where": "body"|"comment",
#     "commentId": id|null}, …]
#
# --from-file <json>: `{"issues": [{"number", "repo", "state", "labels", "body",
#   "comments": [{"id", "body"}], "url"}]}` stands in for the search and reads (fixtures).
#
# Exit: 0 searched (including no hits) · 1 a GitHub call failed · 2 bad arguments.
set -euo pipefail

# Issue bodies never reach a shell: Python runs every gh call as an argument vector.
python3 "$(dirname "${BASH_SOURCE[0]}")"/py/find_marker.py "$@" </dev/null
