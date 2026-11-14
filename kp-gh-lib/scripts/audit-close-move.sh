#!/usr/bin/env bash
# Carries out option B of an `audit-close: M<k>` decision (kp-resolve-spec-decision
# § *Audit-close branch*): moves the listed findings to the next milestone's epic, files
# the closed acceptance audit, closes the decision, then merges and tags M<k>. Every step
# checks before it acts, so a re-run finishes a partial one.
#
# Usage: audit-close-move.sh --repo <T> --issue <n> --milestone M<k> --spec-repo <S>
#                            --item <owner/repo>#<m> [--item …] [--project <owner/number>]
#
# <T> is the repo the decision is filed in; each --item is one finding the decision body
# lists (the caller reads them from the body; this script never parses it).
#
# Steps, in order:
#   1. Next milestone epic: find-marker.sh <S> spec-ref --any-value --scope owner
#      --label type:epic; the lowest `milestone:M<j>` with j > k (numeric), ties by repo
#      then number. None → prints {"target": null} and exits 0, having written nothing.
#   2. Re-parent each item that milestone-of.sh says is OPEN in M<k> under that epic
#      (addSubIssue, replaceParent:true) → moved; already in M<j> → already; else
#      skipped (`closed` or `milestone <id|none>`). blocked-by: lines are not touched.
#   3. Acceptance audit: gh label create type:audit, then file-audit.sh deduped on
#      `audit-unit: milestone:M<k>` and `audit-accepted: <T>#<n>`; closed if still open.
#   4. Close the decision: a `Resolved → no spec change: audit-close. …` comment unless
#      one already starts with `Resolved → `, then gh issue close when still open.
#   5. Merge, then tag, only after step 4 (milestone-gate.sh counts M<k> not done while
#      its decision is open): with --project, milestone-merge.sh --project
#      <owner/number> M<k>, then milestone-tag.sh with the same arguments only when the
#      merge exited 0 (else `"tag": "skipped"`). Each one's stdout lines and exit code
#      are recorded; a non-zero exit never fails this script.
#
# Prints one JSON object on stdout:
#   {"target": "M<j>", "epic": "<owner/repo>#<e>", "moved": [refs], "already": [refs],
#    "skipped": [{"item": ref, "reason": "…"}],
#    "audit": {"number": a, "url": "…", "reused": bool}, "decisionClosed": true,
#    "merge": [lines] | null, "mergeExit": int | null,
#    "tag": [lines] | "skipped" | null, "tagExit": int | null}
#   All four are null without --project; tag is "skipped", tagExit null, when mergeExit
#   is non-zero.
#
# Siblings (find-marker.sh, milestone-of.sh, file-audit.sh, milestone-merge.sh,
# milestone-tag.sh) are found
# through KP_GH_LIB_BIN, default this script's own directory.
#
# Exit: 0 done, including {"target": null} · 1 a gh, find-marker.sh, milestone-of.sh or
# file-audit.sh call failed (no JSON; stderr names the step and the call's first stderr
# line; a re-run finishes) · 2 bad arguments, nothing called.
set -euo pipefail

usage() {
  echo "usage: audit-close-move.sh --repo <T> --issue <n> --milestone M<k> --spec-repo <S>" \
    "--item <owner/repo>#<m> [--item …] [--project <owner/number>]" >&2
  exit 2
}

bad() {
  echo "audit-close-move.sh: $1" >&2
  exit 2
}

repo="" issue="" milestone="" spec_repo="" project=""
items=()
while [ $# -gt 0 ]; do
  case $1 in
    --repo | --issue | --milestone | --spec-repo | --item | --project)
      [ $# -ge 2 ] || bad "$1 needs a value"
      case $1 in
        --repo) repo=$2 ;;
        --issue) issue=$2 ;;
        --milestone) milestone=$2 ;;
        --spec-repo) spec_repo=$2 ;;
        --item) items+=("$2") ;;
        --project) project=$2 ;;
      esac
      shift 2
      ;;
    *) usage ;;
  esac
done

[ -n "$repo" ] || bad "missing --repo"
[ -n "$issue" ] || bad "missing --issue"
[ -n "$milestone" ] || bad "missing --milestone"
[ -n "$spec_repo" ] || bad "missing --spec-repo"
[ ${#items[@]} -gt 0 ] || bad "missing --item"
[[ $issue =~ ^[1-9][0-9]*$ ]] || bad "--issue $issue is not a positive integer"
[[ $milestone =~ ^M[0-9]+$ ]] || bad "--milestone $milestone is not M<number>"
for item in "${items[@]}"; do
  [[ $item =~ ^[^/[:space:]]+/[^/[:space:]]+#[0-9]+$ ]] || bad "--item $item is not <owner/repo>#<number>"
done
if [ -n "$project" ]; then
  [[ $project =~ ^[^/[:space:]]+/[0-9]+$ ]] || bad "--project $project is not <owner/number>"
fi

KP_GH_LIB_BIN="${KP_GH_LIB_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export KP_GH_LIB_BIN

# Issue text never reaches a shell: Python runs every call as an argument vector.
exec python3 "$(dirname "${BASH_SOURCE[0]}")"/py/audit_close_move.py "$repo" "$issue" "$milestone" "$spec_repo" "$project" "${items[@]}" </dev/null
