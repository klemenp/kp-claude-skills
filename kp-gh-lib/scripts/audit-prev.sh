#!/usr/bin/env bash
# Find an audit unit's previous round: the most recently closed `type:audit` issue in the
# spec repo whose body carries the line `audit-unit: <unit>`. `kp-audit-alignment` §0.6
# used to describe this lookup as a `gh … --jq` pipeline; here it is one call with a fixture.
#
# Usage: audit-prev.sh <spec-repo> <unit> <run-dir>
#
# Reads: one `gh issue list -R <spec-repo> --label type:audit --state closed --limit 200
# --json number,body,closedAt`. An issue matches when a line of its body is exactly
# `audit-unit: <unit>` (whole line, case-sensitive); of the matches the one with the
# greatest `closedAt` is the previous round. No audit body is printed.
#
# Writes, into <run-dir> (each via a temp file there, moved into place only once the `gh`
# call succeeded, so a failure leaves both files as they were):
#   prev.json        `{"number": n, "closedAt": "…", "lines": [its body lines starting
#                    with audit-shas:, audit-filed:, unfiled:, refuted: or |, in body
#                    order]}` — `{}` on a first round.
#   prev-refuted.md  its `audit-shas:` line(s), then its `refuted:` lines, one per line —
#                    empty on a first round.
#
# Prints one JSON object: `{"number": n, "prevSpecSha": "<sha>" | null}`, where `<sha>`
# follows `<spec-repo>@` in the space-separated `audit-shas:` entry whose `<owner>/<name>`
# equals <spec-repo> case-insensitively (null when there is no such line or entry); `{}`
# when no closed `type:audit` issue matches — the unit's first round.
#
# Exit: 0 a previous round or a first round · 1 the gh call failed (its stderr passed
# through, nothing on stdout) · 2 bad arguments (checked before any GitHub call).
set -euo pipefail

# Issue bodies never reach a shell: Python runs the gh call as an argument vector.
python3 "$(dirname "${BASH_SOURCE[0]}")"/py/audit_prev.py "$@" </dev/null
