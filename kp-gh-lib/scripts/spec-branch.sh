#!/usr/bin/env bash
# Prepare and publish kp-resolve-spec-decision's spec-update branch, so the leftover-
# worktree, legacy-name, merged-branch and existing-PR cases behave the same on every run.
#
# Usage: spec-branch.sh prepare --spec-repo <owner/repo> --issue <n> [--batch]
#        spec-branch.sh publish --spec-repo <owner/repo> --issue <n> --target-repo <owner/repo>
#          --title <t> --body-file <f>
#        spec-branch.sh publish --spec-repo <owner/repo> --issue <n> --batch --title <t>
#          --body-file <f>
#
# Runs from the spec repo's primary checkout (the current directory); <top> is its
# `git rev-parse --show-toplevel`. Derived names:
#   <repo-name>  the last path component of `git remote get-url origin`, `.git` removed;
#   <base>       `git symbolic-ref --short refs/remotes/origin/HEAD` without `origin/`,
#                start point `origin/<base>`; without that ref, `git rev-parse
#                --abbrev-ref HEAD`, start point `<base>` itself;
#   <branch>     `spec/resolve-<n>`, or `spec/resolve-<n>-batch` with --batch;
#   <worktree>   `<parent of top>/<repo-name>-spec-resolve-<n>[-batch]`;
#   <legacy>     `<parent of top>/spec-resolve-<n>` (none with --batch; never created).
#
# prepare: removes (--force) <worktree> and, without --batch, <legacy> when this checkout's
#   `git worktree list` has them; when <branch> exists locally and the highest-numbered PR
#   on it (`--state all`) is MERGED, deletes it locally and on origin (when there), so it
#   counts as absent; then adds <worktree> on <branch> — new from the start point, or the
#   existing branch. Prints
#   {"worktree": "<worktree>", "branch": "<branch>", "base": "<base>", "reusedBranch": bool}
#
# publish: refuses (exit 2, worktree left in place) an unreadable body file; without
#   --batch, a missing --target-repo or a body not naming <target-repo>#<n>; with --batch,
#   a --target-repo or a body with no `## <owner/repo>#<n>: ` line; a <worktree> this
#   checkout does not list; uncommitted changes in it. Then pushes <branch>, reuses an open
#   PR on it or creates one against <base>, and always removes <worktree>, also after a
#   failed push or create. Prints {"pr": <number>, "url": "<url>", "created": bool}
#
# Exit: 0 done · 1 a git or gh call failed (nothing on stdout, its stderr passed through)
#       · 2 bad arguments or a failed precondition.
set -euo pipefail

# Every git and gh call runs as an argument vector: titles and paths never reach a shell.
python3 "$(dirname "${BASH_SOURCE[0]}")"/py/spec_branch.py "$@" </dev/null
