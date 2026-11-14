#!/usr/bin/env bash
# Runs branch-cleanup.sh against real throwaway repos — a bare `origin` named widget.git
# and a clone of it, rebuilt per scenario under one mktemp -d root — checking its stdout
# line, its exit code and the branches and worktrees it leaves. No network and no gh, so
# this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/branch-cleanup.sh"
failures=0
root="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$root"' EXIT

# Isolate git from the machine's config (hooks, default branch, identity).
export HOME="$root/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com
mkdir -p "$HOME"

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

# sandbox <name> — a fresh $sandbox holding widget.git (origin, with main) and its clone
# $clone on main, whose origin/HEAD points at main, plus a local branch `task/7-demo`
# carrying one commit main lacks (a squash-merged branch looks just like this).
sandbox() {
  sandbox="$root/$1"
  clone="$sandbox/widget"
  mkdir -p "$sandbox"
  git init -q --bare -b main "$sandbox/widget.git"
  git clone -q "$sandbox/widget.git" "$clone" 2>/dev/null
  git -C "$clone" commit -q --allow-empty -m init
  git -C "$clone" push -q origin main
  git -C "$clone" remote set-head origin main >/dev/null
  git -C "$clone" branch -q task/7-demo
  git -C "$clone" worktree add -q "$sandbox/scratch" task/7-demo 2>/dev/null
  git -C "$sandbox/scratch" commit -q --allow-empty -m "task work"
  git -C "$clone" worktree remove "$sandbox/scratch"
}

# expect <label> <want-exit> <want-stdout> <args…>, run from $from (default $clone). The
# literal SANDBOX in <want-stdout> stands for $sandbox.
expect() {
  local label=$1 want_exit=$2 want_stdout=${3//SANDBOX/$sandbox}
  shift 3
  local exit_code
  echo "== $label"
  stdout="$(cd "${from:-$clone}" && "$script" "$@" 2>/dev/null)"
  exit_code=$?
  if [ "$exit_code" -eq "$want_exit" ]; then
    check "$label exit" ok
  else
    check "$label exit" "exit $exit_code, want $want_exit"
  fi
  if [ "$stdout" = "$want_stdout" ]; then
    check "$label stdout" ok
  else
    check "$label stdout" "got '$stdout', want '$want_stdout'"
  fi
}

# state <label> <want> <actual> — one assertion on the git state a run left.
state() {
  if [ "$2" = "$3" ]; then
    check "$1" ok
  else
    check "$1" "got '$3', want '$2'"
  fi
}

has_branch() {
  if git -C "$clone" show-ref --verify --quiet "refs/heads/$1"; then echo yes; else echo no; fi
}

listed() {
  if git -C "$clone" worktree list --porcelain | grep -Fxq "worktree $1"; then echo yes; else echo no; fi
}

# --- deleted ------------------------------------------------------------------------

sandbox deleted
expect deleted 0 "branch=task/7-demo result=deleted" task/7-demo
state "deleted branch gone" no "$(has_branch task/7-demo)"

# --- absent -------------------------------------------------------------------------

sandbox absent
expect absent 0 "branch=task/9-never result=absent" task/9-never

# --- clean worktree removed then deleted --------------------------------------------

sandbox clean-worktree
git -C "$clone" worktree add -q "$sandbox/widget-task-7" task/7-demo 2>/dev/null
expect "clean worktree removed then deleted" 0 \
  "branch=task/7-demo result=deleted-after-worktree-remove:SANDBOX/widget-task-7" task/7-demo
state "clean worktree directory gone" no "$([ -e "$sandbox/widget-task-7" ] && echo yes || echo no)"
state "clean worktree branch gone" no "$(has_branch task/7-demo)"

# --- dirty worktree kept ------------------------------------------------------------

sandbox dirty-worktree
git -C "$clone" worktree add -q "$sandbox/widget-task-7" task/7-demo 2>/dev/null
touch "$sandbox/widget-task-7/untracked.txt"
expect "dirty worktree kept" 0 \
  "branch=task/7-demo result=kept-dirty-worktree:SANDBOX/widget-task-7" task/7-demo
state "dirty worktree branch kept" yes "$(has_branch task/7-demo)"
state "dirty worktree still listed" yes "$(listed "$sandbox/widget-task-7")"

# --- pruned worktree ----------------------------------------------------------------

sandbox pruned-worktree
git -C "$clone" worktree add -q "$sandbox/widget-task-7" task/7-demo 2>/dev/null
rm -r "$sandbox/widget-task-7"
expect "pruned worktree" 0 "branch=task/7-demo result=deleted" task/7-demo
state "pruned worktree branch gone" no "$(has_branch task/7-demo)"
state "pruned worktree no longer listed" no "$(listed "$sandbox/widget-task-7")"

# --- refusals -----------------------------------------------------------------------

sandbox default-branch
git -C "$clone" switch -q --detach
expect "default branch refused" 2 "" main
state "default branch kept" yes "$(has_branch main)"

sandbox current-branch
git -C "$clone" switch -q -c side
expect "current branch refused" 2 "" side
state "current branch kept" yes "$(has_branch side)"

sandbox from-worktree
git -C "$clone" worktree add -q "$sandbox/widget-task-7" task/7-demo 2>/dev/null
git -C "$clone" branch -q other
from="$sandbox/widget-task-7" expect "from worktree refused" 2 "" other
state "from worktree branch kept" yes "$(has_branch other)"

sandbox bad-arguments
expect "no argument" 2 ""
expect "two arguments" 2 "" task/7-demo extra
expect "invalid branch name" 2 "" "bad..name"
state "bad arguments branch kept" yes "$(has_branch task/7-demo)"

echo "mismatches: $failures"
[ "$failures" -eq 0 ]
