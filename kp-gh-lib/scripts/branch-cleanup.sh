#!/usr/bin/env bash
# Delete a merged PR's local branch from the primary checkout. A squash merge leaves the
# branch unmerged in git's eyes and `git worktree remove` keeps it, so without this every
# merged task branch stays in the primary checkout forever. The pr-loop close-out runs it.
#
# Usage: branch-cleanup.sh <branch>
#
# Run with the primary checkout as the working directory, after the PR on <branch>
# merged. First `git worktree prune`, so a worktree whose directory is gone no longer
# counts; then a linked worktree that has <branch> checked out is removed when its
# `git status --porcelain` is empty, and kept, with the branch, otherwise. The branch is
# deleted with `git branch -D`. Never touches the remote.
#
# Prints one line on every exit-0 path:
#   branch=<branch> result=<r>
# where <r> is one of
#   deleted                               the branch is gone
#   deleted-after-worktree-remove:<path>  a clean worktree on it was removed first
#   absent                                refs/heads/<branch> did not exist
#   kept-dirty-worktree:<path>            a worktree on it has changes; both left as is
#   kept-unreadable-worktree:<path>       its status could not be read; both left as is
# Exit 1 and exit 2 print nothing on stdout and one line on stderr.
#
# Exit: 0 done · 1 a git command failed · 2 bad arguments: not exactly one argument, an
# invalid branch name, run from a linked worktree, or <branch> is the default branch or
# the primary checkout's current branch.
set -euo pipefail

refuse() {
  echo "branch-cleanup.sh: $1" >&2
  exit 2
}

[ $# -eq 1 ] || refuse "usage: branch-cleanup.sh <branch>"
branch=$1
git check-ref-format --branch "$branch" >/dev/null 2>&1 || refuse "invalid branch name: $branch"

top="$(git rev-parse --show-toplevel)"
common="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
own_git="$(cd "$top" && pwd -P)/.git"
[ "$common" = "$own_git" ] || refuse "run from a linked worktree ($top), not the primary checkout"

default="$(git symbolic-ref --short -q refs/remotes/origin/HEAD || true)"
default="${default#origin/}"
default="${default:-main}"
[ "$branch" != "$default" ] || refuse "refusing to delete the default branch $branch"
current="$(git symbolic-ref --short -q HEAD || true)"
[ "$branch" != "$current" ] || refuse "refusing to delete the current branch $branch"

if ! git show-ref --verify --quiet "refs/heads/$branch"; then
  echo "branch=$branch result=absent"
  exit 0
fi

git worktree prune

# The linked worktree that has <branch> checked out, if any: porcelain lists each as a
# `worktree <path>` line followed, unless detached, by its `branch refs/heads/<name>`.
worktree_path=""
while IFS= read -r line; do
  case "$line" in
    "worktree "*) path="${line#worktree }" ;;
    "branch refs/heads/$branch") worktree_path="$path" ;;
  esac
done < <(git worktree list --porcelain)

if [ -n "$worktree_path" ]; then
  if ! status="$(git -C "$worktree_path" status --porcelain 2>/dev/null)"; then
    echo "branch=$branch result=kept-unreadable-worktree:$worktree_path"
    exit 0
  fi
  if [ -n "$status" ]; then
    echo "branch=$branch result=kept-dirty-worktree:$worktree_path"
    exit 0
  fi
  git worktree remove "$worktree_path" >&2
fi

git branch -D "$branch" >/dev/null
if [ -n "$worktree_path" ]; then
  echo "branch=$branch result=deleted-after-worktree-remove:$worktree_path"
else
  echo "branch=$branch result=deleted"
fi
