#!/usr/bin/env bash
# Read one PR's review-verdict state from its issue comments, in one call.
#
# `kp-review-gh-pr` posts one verdict comment per round carrying the marker
# `<!-- kp-review-gh-pr:verdict -->`; `kp-fix-pr` posts one summary per fix run carrying
# `<!-- kp-fix-pr:summary -->`. Three skills used to page through every comment and parse
# them in prose; this prints the same state as JSON so each reads only the fields it needs.
#
# Usage: pr-verdict-state.sh <owner/repo> <pr> [--history] [--reviews]
#        pr-verdict-state.sh --from-file <fixture.json> [--history] [--reviews]
#
# Prints one JSON object on stdout:
#   {"head": "<current head sha>",
#    "verdict": {"id":…, "verdict":"APPROVED"|"REQUEST_CHANGES", "reviewed":"<sha>"|null,
#                "atHead":true|false, "createdAt":…, "updatedAt":…} | null,
#    "denial":  {"id":…, "reviewed":"<sha>"|null, "createdAt":…, "updatedAt":…,
#                "findings":"<Findings section text only>", "count":<top-level bullets>,
#                "fingerprint":"<sha256 of the whitespace-normalised section>",
#                "bySeverity":{"blockers":n,"major":n|null,"minor":n|null,"nits":n|null,
#                              "ci":n,"combined":n|null}} | null,
#    "fixSummary": {"id":…, "createdAt":…, "updatedAt":…, "body":"<text>"} | null,
#    "rounds": {"verdicts":n, "denials":n, "fixSummaries":n}}
#
# `verdict` is the latest verdict comment and `denial` the latest one requesting changes,
# both by `updated_at` — the ordering key the calling skills already used. A marked
# comment is an approval only when it carries a `verdict: APPROVED` line; anything else,
# including the pre-2026-09 format with no `verdict:` line at all, is a denial. The SHA
# line is `approved:` on an approval and `reviewed:` on a denial; either lands in
# `reviewed`, the head the verdict was made against. `fixSummary` is the latest fix
# summary newer than `denial` (so `kp-fix-pr`'s "already addressed" stop is one field
# lookup), or null when the denial is the newer of the two.
#
# `--history` adds a `history` array — every verdict and fix summary oldest to newest by
# creation time, each with its stripped `body` and, for a denial, its `findings`.
# `kp-review-gh-pr` needs the whole run of rounds, not just the latest, to honour its
# do-not-re-raise rule; the other two callers read the lean default.
#
# Every body has the `<!-- human-only:start … -->` fence stripped before anything reads
# it, and `### TL;DR (for humans)` never reaches `findings` or a history `body`.
#
# `--reviews` adds the formal-review channel (`/pulls/<n>/reviews`), read only under this
# flag, and two keys:
#   "latest":    {"channel":"review"|"comment", "verdict":"APPROVED"|"REQUEST_CHANGES",
#                 "at":"<ISO-8601>", "id":<review or comment id>} | null
#   "fixNeeded": true|false
# `latest` is the newer of the newest formal review whose state is APPROVED or
# CHANGES_REQUESTED (by `submitted_at`; CHANGES_REQUESTED reads as REQUEST_CHANGES) and the
# `verdict` comment (by `updatedAt`). The review wins only when strictly newer; on a tie the
# comment wins. `fixNeeded` is true only when `latest.verdict` is REQUEST_CHANGES and no fix
# summary has an `updatedAt` strictly newer than `latest.at`. A `--from-file` fixture
# carries the reviews as an optional `"reviews"` array in the REST shape (`id`, `state`,
# `submitted_at`, `body`); a missing key is `[]`.
#
# Exit: 0 read · 1 GitHub failure · 2 bad arguments.
set -euo pipefail

usage() {
  echo "usage: pr-verdict-state.sh <owner/repo> <pr> [--history] [--reviews]" >&2
  echo "       pr-verdict-state.sh --from-file <fixture.json> [--history] [--reviews]" >&2
  exit 2
}

repo_ref=""
pr=""
fixture=""
history=false
reviews=false

while [ $# -gt 0 ]; do
  case "$1" in
    --history) history=true; shift ;;
    --reviews) reviews=true; shift ;;
    --from-file) [ $# -ge 2 ] || usage; fixture=$2; shift 2 ;;
    -*) usage ;;
    *)
      if [ -z "$repo_ref" ]; then repo_ref=$1
      elif [ -z "$pr" ]; then pr=$1
      else usage
      fi
      shift ;;
  esac
done

if [ -n "$fixture" ]; then
  if [ -n "$repo_ref" ] || [ -n "$pr" ]; then usage; fi
  [ -f "$fixture" ] || { echo "pr-verdict-state.sh: no such fixture: $fixture" >&2; exit 2; }
else
  if [ -z "$repo_ref" ] || [ -z "$pr" ]; then usage; fi
  [[ $repo_ref =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || usage
  [[ $pr =~ ^[0-9]+$ ]] || usage
fi

python3 "$(dirname "${BASH_SOURCE[0]}")"/py/pr_verdict_state.py "$repo_ref" "$pr" "$fixture" "$history" "$reviews" </dev/null
