#!/usr/bin/env bash
# Add, replace or remove one marker line — `<marker>: <value>` — on an issue body, outside
# the human-only fence and every <details> block, idempotently. The kp-* skills' marker
# hand edits (re-pointing a `blocked-by:` edge, clearing a waiter, adding a `spec-pr:`)
# used to describe the edit in prose; this is that edit, once.
#
# Usage: set-marker.sh <owner/repo> <n> <marker>
#          (--add <value> | --replace <old> <new> | --remove <value>) [--from-file <json>]
#
# Read: `gh issue view <n> -R <owner/repo> --json body --jq .body`. Write, only when the
# body changed: `gh issue edit <n> -R <owner/repo> --body-file <tmp>`. No change, no write.
#
# Eligible lines: a line counts only when it lies wholly outside every human-only fence and
# every <details> … </details> block, by find-marker.sh's rules (nesting counted; an
# unclosed start fences to the end of the body). A line that is inside, or shares any
# character with a fence or <details> block, is never read, changed or removed.
#
# Matching: a line matches `<marker>: <value>` when, trimmed, it is exactly that text, bare
# or as a whole `<!-- <marker>: <value> -->` line — case-sensitive. An issue reference
# matches both forms, judged from <owner/repo> (the edited issue's repo): `#38` matches
# `#38` and `<owner/repo>#38`, and the reverse. `#380` never matches `#38`, and a line
# carrying several values (`blocked-by: #38 #39`) never matches.
#
#   --add <value>          no change when a matching line exists; else the line
#                          `<marker>: <value>` goes directly after the last eligible
#                          `<marker>:` line (any value), or, with none, at the end of the
#                          body — after one blank line unless the last non-empty line is
#                          already a `<word>: <text>` marker line.
#   --replace <old> <new>  every matching <old> line becomes `<marker>: <new>`, keeping its
#                          indentation and bare-or-comment form; when a line already
#                          matches <new>, the <old> lines are deleted instead. No <old>
#                          line, or <old> and <new> naming the same value → no change.
#   --remove <value>       every matching line is deleted. None → no change.
# Line endings and every other byte of the body are preserved.
#
# Prints one JSON object: {"changed": true|false}.
# --from-file <json>: `{"body": "<text>"}` stands in for the read (fixtures); no GitHub call
#   is made and the output is {"changed": true|false, "body": "<resulting body>"}.
#
# Exit: 0 done (including no change) · 1 a gh call failed · 2 bad arguments.
set -euo pipefail

# Issue bodies never reach a shell: Python runs every gh call as an argument vector.
python3 "$(dirname "${BASH_SOURCE[0]}")"/py/set_marker.py "$@" </dev/null
