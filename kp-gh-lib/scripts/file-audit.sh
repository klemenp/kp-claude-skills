#!/usr/bin/env bash
# File a closed `type:audit` report issue in one call. kp-audit-alignment §8.3 (an audit
# round's report) and kp-resolve-spec-decision § *Audit-close branch* option B step 3 (an
# operator-accepted milestone) both file one; this script is the one copy of the label,
# the dedup, the `__TOKENS__` fill and the close. A `type:audit` report is never placed,
# assigned or added to a board, so it does not go through create-item.sh.
#
# Usage: file-audit.sh --repo <owner/repo> --title <t> --body-file <f>
#                      [--tokens <start-iso> <marker>] [--dedup-line '<marker>: <value>']…
#
# Arguments are checked before any GitHub call: --repo, --title and a readable
# --body-file are given; every --dedup-line is `<marker>: <value>` (marker
# [A-Za-z0-9_-]+, one `: `, a non-empty value); --tokens needs `__TOKENS__` in the body.
#
# Steps, in order:
#   1. ensure-labels.sh --repo <repo> type:audit.
#   2. Dedup, only with --dedup-line: find-marker.sh <repo> <marker> <value> --state all
#      --label type:audit per line; an issue is a hit only when every line's search
#      returned it. On a hit, the highest-numbered one is closed if still open and printed
#      with "reused": true — nothing is created and no token row is filled.
#   3. gh issue create -R <repo> --title <t> --label type:audit --body-file <f>.
#   4. Token fill, only with --tokens: report-tokens.sh <start-iso> <marker> <repo> <n>;
#      its row replaces every `__TOKENS__` in a copy of the body, written back with
#      gh issue edit --body-file. Best-effort: a failure prints
#      `file-audit: token fill skipped — <reason>` on stderr and the script carries on.
#   5. gh issue close <n> -R <repo>.
#
# Prints one JSON object on stdout:
#   {"number": 12, "url": "https://github.com/…/issues/12", "reused": false}
#
# Siblings (ensure-labels.sh, find-marker.sh, report-tokens.sh) are found through
# KP_GH_LIB_BIN, default this script's own directory.
#
# Exit: 0 filed or reused · 1 a GitHub or sibling call failed (stderr says which; after a
# failed close the issue exists, open) · 2 bad arguments, nothing called.
set -euo pipefail

KP_GH_LIB_BIN="${KP_GH_LIB_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export KP_GH_LIB_BIN

# The body never reaches a shell: Python runs every call as an argument vector.
exec python3 "$(dirname "${BASH_SOURCE[0]}")"/py/file_audit.py "$@" </dev/null
