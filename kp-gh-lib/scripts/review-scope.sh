#!/usr/bin/env bash
# Decide a kp-review-gh-pr re-review round's scope — the fix diff or the whole PR — and
# hash the linked item's body, in one call. `kp-review-gh-pr` §1.5 and §1.7 used to
# re-derive five conditions and a body hash by hand every round.
#
# Usage: review-scope.sh <owner/repo> <pr> <issue|-> <headRefName>
#          [--state-file <json>] [--body-file <file>]
#
# Runs `git` in the current directory, which must be the checkout whose
# `origin/<headRefName>` kp-review-gh-pr §0.2's fetch updated. <issue> is the linked coding
# item; `-` means a spec PR or a PR with no linked issue.
#
# --state-file <json>: the stdout of `pr-verdict-state.sh <owner/repo> <pr> --history`;
#   without it this script runs that command itself. Only its `history` array is read.
# --body-file <file>: the item body's bytes, instead of
#   `gh issue view <issue> -R <owner/repo> --json body -q .body`.
#
# Body hash: SHA-256 hex of the body piped through `body-parts.py strip` (text mode, so
# `\r\n` reads as `\n`) — byte-identical to the one-liner every earlier verdict's
# `body-sha256:` was computed with. An empty body hashes the empty string.
#
# Scope: `fix-diff` only when all of these hold, in order; the first that fails names the
# reason in `scope: full (<reason>)`:
#   1. the newest verdict in `history` (oldest first by createdAt) is a REQUEST_CHANGES
#      with a `reviewed` SHA                                         — `no prior denial`
#   2. a fix summary newer than that denial carries a `pushed: <sha>` line — `no fix push`
#   3. `git merge-base --is-ancestor <reviewed> origin/<headRefName>` exits 0
#                                                                — `reviewed not an ancestor`
#   4. every path `git diff --name-status <reviewed>..origin/<headRefName>` names (both
#      paths of a rename or copy) is a file the denial's findings flag (`path:line`
#      bullets) or a test file                                 — `fix outside flagged files`
#   5. <issue> is not `-` and the denial has a `body-sha256:` line   — `no body hash`;
#      that hash equals the current body's                          — `item body changed`
#
# Prints exactly three lines:
#   scope: fix-diff | scope: full (<reason>)
#   reviewed: <sha> | reviewed: -        (the SHA whenever condition 1 held)
#   bodySha: <64 hex> | bodySha: -       (every round; `-` when <issue> is `-`)
#
# Exit: 0 decided (either scope) · 1 a gh read, pr-verdict-state.sh or the git diff
#       failed · 2 bad arguments.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

# Comment and issue text never reach a shell: Python runs every gh and git call as an
# argument vector.
python3 "$(dirname "${BASH_SOURCE[0]}")"/py/review_scope.py "$here" "$@" </dev/null
