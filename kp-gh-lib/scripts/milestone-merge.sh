#!/usr/bin/env bash
# Merges a done milestone's integration branch `release/M<k>` into the default branch of
# every repo that holds one of its epics, items, audits or audit-close decisions
# (NOTES.md § *Milestone sequencing* → *Audit gate*, *Milestone branch*), so the
# `milestone/M<k>` tag milestone-tag.sh places next lands on the merge commit. Done and
# the repo set both come from `milestone-gate.sh --milestone`, like the tag's.
#
# Usage: milestone-merge.sh --project <owner/number> M<k>
#
# Per repo carrying `release/M<k>`: the default branch is merged into it (POST
# repos/{r}/merges), the open `release/M<k>` → default PR is found or created (body
# carries `milestone-merge: M<k>` and no closing keyword), its CI is waited on
# (`gh pr checks --watch`, 540 s), and it is merged with `--merge --delete-branch`.
# A whole-milestone merge never lands without CI having run (decision #343): when the
# watch reports `no checks reported`, `gh pr checks` is re-polled after `sleep 30` up to
# 10 times (60 s per re-poll), and once checks appear the watch runs again and decides.
# Only a PR still reporting no checks after the 10th re-poll counts as a pass. One repo's
# wait is therefore bounded by 540 + 10 × (30 + 60) + 540 s — past the 10-minute Bash
# cap, so a caller runs this detached with an exit sentinel.
#
# Prints one line per outcome on stdout:
#   not-done M<k>                          the milestone is not done; nothing is touched
#   no-branch <owner/repo>                 the repo has no release/M<k> (spec repos never do)
#   conflict <owner/repo>: <first error line>  syncing the default branch in hit a conflict
#   ci-failed <owner/repo> <pr>            a check on the merge PR failed
#   ci-pending <owner/repo> <pr>           checks were still pending after a 540 s watch
#   failed <owner/repo>: <first stderr line>  a lookup, the PR create or the merge failed
#   merged <owner/repo> <pr> <sha>         merged; <sha> is the new default-branch HEAD
# A failed repo never stops the others. A merged repo's branch is deleted, so a re-run
# reports it `no-branch` and retries only the repos still carrying release/M<k>.
#
# The merge is a merge commit, never a squash: the per-task squash commits on the branch
# are what trace-matrix.sh maps to items. `.claude/hooks/guard_merge.py`, which demands
# `--squash`, guards only Claude sessions rooted in kp-skills; this script runs from a
# spec checkout against code repos, so the merge commit is intentional, not a bypass.
#
# milestone-gate.sh is found through KP_GH_LIB_BIN, default this script's own directory.
#
# Exit: 0 every repo merged or no-branch, or not-done · 1 the gate lookup or a repo
# failed · 2 bad arguments.
set -euo pipefail

usage() {
  echo "usage: milestone-merge.sh --project <owner/number> M<k>" >&2
  exit 2
}

[ $# -eq 3 ] || usage
[ "$1" = --project ] || usage
[[ $2 =~ ^[^/[:space:]]+/[0-9]+$ ]] || usage
[[ $3 =~ ^M[0-9]+$ ]] || usage

KP_GH_LIB_BIN="${KP_GH_LIB_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export KP_GH_LIB_BIN

exec python3 "$(dirname "${BASH_SOURCE[0]}")"/py/milestone_merge.py "$2" "$3" </dev/null
