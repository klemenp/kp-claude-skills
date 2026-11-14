#!/usr/bin/env bash
# kp-resolve-spec-decision §4.7's fast path from its sonnet read's answer to a posted
# approval: the CI wait, the per-decision structural checks, the head re-check and the
# approval verdict comment, in one call. It posts the approval but never lands the PR —
# that stays the skill's own `Bash` call, where the `guard_merge.py` PreToolUse gate sees
# it. The comment is the format `guard_merge.py` reads (CLAUDE.md § *Enforcement*): change
# it only together with that gate and the files that section lists.
#
# Usage: spec-pr-fastmerge.sh <spec-repo> <pr> --decision <owner/repo>#<n>
#                             [--decision <owner/repo>#<n>]… --checked-head <40-hex sha>
#                             --key <spec-ref key> [--key <k>]… --read <answer>
#
# Steps, in order; the first fallback stops the run:
#   1. --read is not exactly `ok`                → fallback: read: <answer>  (no gh call)
#   2. gh pr checks --watch, 540 s timeout       → fallback: ci pending  (timed out or
#      exit 8); `no checks reported` and any other exit go on (step 3 fails a red check)
#   3. spec-pr-check.sh once per --decision, in argument order:
#        exit 1  → fallback: spec-pr-check <owner/repo>#<n>: <FAIL lines joined " | ">
#        other   → fallback: spec-pr-check <owner/repo>#<n> exit <code>: <first stderr line>
#   4. headRefOid re-read                        → fallback: head read failed
#                                                → fallback: head moved <old7>..<new7>
#   5. gh pr comment the approval                → fallback: comment failed: <stderr line>
#
# The approval carries one `Decision` line per --decision, then one `spec-ref:` line per
# --key, both in argument order.
#
# spec-pr-check.sh is found through KP_GH_LIB_BIN, default this script's own directory.
#
# Output: exactly one stdout line, `approved <checked-head>` or `fallback: <trigger>`.
# Exit: 0 approved · 3 fallback · 2 bad arguments (usage on stderr, no gh call).
set -euo pipefail

KP_GH_LIB_BIN="${KP_GH_LIB_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export KP_GH_LIB_BIN

exec python3 "$(dirname "${BASH_SOURCE[0]}")"/py/spec_pr_fastmerge.py "$@" </dev/null
