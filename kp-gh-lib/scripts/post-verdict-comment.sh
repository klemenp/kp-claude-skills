#!/usr/bin/env bash
# Post a `kp-review-gh-pr` verdict comment or a `kp-fix-pr` fix summary on a PR, deciding
# whether it `PATCH`es a true re-run of the latest one or stacks a new round. Both skills
# used to carry this rule as inline bash; this is the one writer of those two comments.
#
# Usage: post-verdict-comment.sh <owner/repo> <pr> --kind verdict|fixSummary
#          --body-file <file>
#
# Body: `--kind verdict` → line 1 is exactly `<!-- kp-review-gh-pr:verdict -->`, line 2
# `verdict: APPROVED` or `verdict: REQUEST_CHANGES`, line 3 `approved: <sha>` for an
# approval or `reviewed: <sha>` for a denial. `--kind fixSummary` → line 1 is exactly
# `<!-- kp-fix-pr:summary -->`, line 2 `pushed: <sha>`. <sha> is a full 40-hex SHA and
# must be the PR's current head. The file's bytes are posted unmodified.
#
# State: one `pr-verdict-state.sh <owner/repo> <pr> --history` call (found through
# KP_GH_LIB_BIN, default this script's own directory); its `.head` is the head SHA.
#
# Rules — PATCH only a true re-run, otherwise create a new comment:
#   verdict    — the last `verdict` entry of `.history` exists, its body holds the body
#                file's line 2 and line 3 each as a whole line, and no `fixSummary`
#                entry was created after it.
#   fixSummary — `.fixSummary` (the latest summary newer than the latest denial) is
#                non-null and its body holds `pushed: <head>` as a whole line.
#
# Prints one JSON object on stdout: {"action": "patched"|"created", "id": <comment id>}.
#
# Exit: 0 posted · 1 a GitHub call failed (state read or write) · 2 bad arguments or body
#       · 3 head moved (body SHA is not the PR head; nothing posted).
set -euo pipefail

KP_GH_LIB_BIN="${KP_GH_LIB_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export KP_GH_LIB_BIN

# The body never reaches a shell: Python runs every call as an argument vector.
exec python3 "$(dirname "${BASH_SOURCE[0]}")"/py/post_verdict_comment.py "$@" </dev/null
