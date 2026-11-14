#!/usr/bin/env bash
# Runs worktree.sh against real throwaway repos — a bare `origin` named widget.git and a
# clone of it, rebuilt per scenario under one mktemp -d root — checking its stdout JSON,
# its exit code and the git state it leaves. No network and no gh, so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/worktree.sh"
failures=0
root="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$root"' EXIT

# Isolate git from the machine's config (hooks, default branch, identity).
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

# sandbox <name> — a fresh $sandbox holding widget.git (origin, with main and a pushed
# `feature` branch) and its clone $clone; the clone's origin/HEAD points at main.
sandbox() {
  sandbox="$root/$1"
  clone="$sandbox/widget"
  mkdir -p "$sandbox"
  git init -q --bare -b main "$sandbox/widget.git"
  git clone -q "$sandbox/widget.git" "$clone" 2>/dev/null
  git -C "$clone" commit -q --allow-empty -m init
  git -C "$clone" push -q origin main
  git -C "$clone" branch -q feature
  git -C "$clone" push -q origin feature
  git -C "$clone" branch -q -D feature
  git -C "$clone" remote set-head origin main >/dev/null
}

# push_to_origin <branch> — a commit on <branch> that only origin has.
push_to_origin() {
  local other="$sandbox/other"
  [ -d "$other" ] || git clone -q "$sandbox/widget.git" "$other" 2>/dev/null
  git -C "$other" fetch -q origin
  git -C "$other" checkout -q -B "$1" "origin/$1"
  git -C "$other" commit -q --allow-empty -m "origin moves $1"
  git -C "$other" push -q origin "$1"
}

# expect <label> <want-exit> <want-stdout> <worktree.sh args…>, run from $clone. The
# literal SANDBOX in <want-stdout> stands for $sandbox.
expect() {
  local label=$1 want_exit=$2 want_stdout=${3//SANDBOX/$sandbox}
  shift 3
  local exit_code
  echo "== $label"
  stdout="$(cd "$clone" && "$script" "$@" 2>/dev/null)"
  exit_code=$?
  if [ "$exit_code" -eq "$want_exit" ]; then
    check "$label exit" ok
  else
    check "$label exit" "exit $exit_code, want $want_exit"
  fi
  if diff -u <(printf '%s' "$want_stdout") <(printf '%s' "$stdout"); then
    check "$label stdout" ok
  else
    check "$label stdout" MISMATCH
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

listed() {
  if git -C "$clone" worktree list --porcelain | grep -Fxq "worktree $1"; then
    echo yes
  else
    echo no
  fi
}

head_of() {
  git -C "$1" rev-parse "$2"
}

branch_of() {
  git -C "$1" symbolic-ref --quiet --short HEAD || echo detached
}

# --- task --------------------------------------------------------------------------

sandbox task-new
expect task-new 0 '{"path":"SANDBOX/widget-task-7","reused":false,"legacy":false,"ffSkipped":false}' \
  task 7 add-thing
state "task-new branch" task/7-add-thing "$(branch_of "$sandbox/widget-task-7")"
state "task-new base" "$(head_of "$clone" origin/main)" "$(head_of "$sandbox/widget-task-7" HEAD)"

sandbox task-existing-branch
git -C "$clone" branch -q task/7-add-thing origin/feature
expect task-existing-branch 0 '{"path":"SANDBOX/widget-task-7","reused":false,"legacy":false,"ffSkipped":false}' \
  task 7 add-thing
state "task-existing-branch checkout" "$(head_of "$clone" origin/feature)" \
  "$(head_of "$sandbox/widget-task-7" HEAD)"

sandbox task-reuse
git -C "$clone" worktree add -q "$sandbox/widget-task-7" -b task/7-add-thing main 2>/dev/null
expect task-reuse 0 '{"path":"SANDBOX/widget-task-7","reused":true,"legacy":false,"ffSkipped":false}' \
  task 7 add-thing

sandbox task-legacy
git -C "$clone" worktree add -q "$sandbox/task-7" -b task/7-add-thing main 2>/dev/null
expect task-legacy 0 '{"path":"SANDBOX/task-7","reused":true,"legacy":true,"ffSkipped":false}' \
  task 7 add-thing
state "task-legacy no new name" no "$(listed "$sandbox/widget-task-7")"

sandbox task-base
expect task-base 0 '{"path":"SANDBOX/widget-task-7","reused":false,"legacy":false,"ffSkipped":false}' \
  task 7 add-thing --base origin/feature
git -C "$clone" commit -q --allow-empty -m "main only"
state "task-base honoured" "$(head_of "$clone" origin/feature)" "$(head_of "$sandbox/widget-task-7" HEAD)"

# A milestone item: kp-do-gh-task passes its fetched release branch as the base.
sandbox task-milestone-base
git -C "$clone" checkout -q -b release/M7
git -C "$clone" commit -q --allow-empty -m "milestone M7 work"
git -C "$clone" push -q origin release/M7
git -C "$clone" checkout -q main
git -C "$clone" branch -q -D release/M7
expect task-milestone-base 0 '{"path":"SANDBOX/widget-task-7","reused":false,"legacy":false,"ffSkipped":false}' \
  task 7 add-thing --base origin/release/M7
state "task-milestone-base branch" task/7-add-thing "$(branch_of "$sandbox/widget-task-7")"
state "task-milestone-base at release/M7" "$(head_of "$clone" origin/release/M7)" \
  "$(head_of "$sandbox/widget-task-7" HEAD)"
state "task-milestone-base not origin/HEAD" no \
  "$([ "$(head_of "$clone" origin/HEAD)" = "$(head_of "$sandbox/widget-task-7" HEAD)" ] && echo yes || echo no)"

# --- fix ---------------------------------------------------------------------------

sandbox fix-new
expect fix-new 0 '{"path":"SANDBOX/widget-fix-pr-12","reused":false,"legacy":false,"ffSkipped":false}' \
  fix 12 feature
state "fix-new branch checkout" feature "$(branch_of "$sandbox/widget-fix-pr-12")"

sandbox fix-origin-ahead
git -C "$clone" worktree add -q "$sandbox/widget-fix-pr-12" feature 2>/dev/null
push_to_origin feature
expect fix-origin-ahead 0 '{"path":"SANDBOX/widget-fix-pr-12","reused":true,"legacy":false,"ffSkipped":false}' \
  fix 12 feature
state "fix-origin-ahead fast-forwarded" "$(head_of "$clone" origin/feature)" \
  "$(head_of "$sandbox/widget-fix-pr-12" HEAD)"

sandbox fix-local-ahead
git -C "$clone" worktree add -q "$sandbox/widget-fix-pr-12" feature 2>/dev/null
git -C "$sandbox/widget-fix-pr-12" commit -q --allow-empty -m "unpushed fix"
unpushed="$(head_of "$sandbox/widget-fix-pr-12" HEAD)"
expect fix-local-ahead 0 '{"path":"SANDBOX/widget-fix-pr-12","reused":true,"legacy":false,"ffSkipped":true}' \
  fix 12 feature
state "fix-local-ahead not moved" "$unpushed" "$(head_of "$sandbox/widget-fix-pr-12" HEAD)"

sandbox fix-legacy
git -C "$clone" worktree add -q "$sandbox/fix-pr-12" feature 2>/dev/null
push_to_origin feature
expect fix-legacy 0 '{"path":"SANDBOX/fix-pr-12","reused":true,"legacy":true,"ffSkipped":false}' \
  fix 12 feature
state "fix-legacy fast-forwarded" "$(head_of "$clone" origin/feature)" \
  "$(head_of "$sandbox/fix-pr-12" HEAD)"
state "fix-legacy no new name" no "$(listed "$sandbox/widget-fix-pr-12")"

# --- review ------------------------------------------------------------------------

sandbox review-add
expect review-add 0 '{"path":"SANDBOX/widget-review-pr-12","reused":false,"legacy":false,"ffSkipped":false}' \
  review 12 feature
state "review-add detached" detached "$(branch_of "$sandbox/widget-review-pr-12")"
state "review-add at head" "$(head_of "$clone" origin/feature)" \
  "$(head_of "$sandbox/widget-review-pr-12" HEAD)"

sandbox review-stale
git -C "$clone" worktree add -q --detach "$sandbox/widget-review-pr-12" main 2>/dev/null
touch "$sandbox/widget-review-pr-12/leftover"
expect review-stale 0 '{"path":"SANDBOX/widget-review-pr-12","reused":false,"legacy":false,"ffSkipped":false}' \
  review 12 feature
state "review-stale re-added at head" "$(head_of "$clone" origin/feature)" \
  "$(head_of "$sandbox/widget-review-pr-12" HEAD)"
state "review-stale leftover gone" no "$([ -e "$sandbox/widget-review-pr-12/leftover" ] && echo yes || echo no)"

sandbox review-legacy
git -C "$clone" worktree add -q --detach "$sandbox/review-pr-12" main 2>/dev/null
expect review-legacy 0 '{"path":"SANDBOX/widget-review-pr-12","reused":false,"legacy":false,"ffSkipped":false}' \
  review 12 feature
state "review-legacy removed" no "$(listed "$sandbox/review-pr-12")"

sandbox review-reclaim-only
git -C "$clone" worktree add -q --detach "$sandbox/widget-review-pr-12" main 2>/dev/null
expect review-reclaim-only 0 '{"path":null,"reused":false,"legacy":false,"ffSkipped":false}' \
  review 12 feature --reclaim-only
state "review-reclaim-only nothing added" no "$(listed "$sandbox/widget-review-pr-12")"

# --- bad arguments -----------------------------------------------------------------

sandbox bad-arguments
expect no-mode 2 ""
expect unknown-mode 2 "" build 7 add-thing
expect missing-positional 2 "" task 7
expect non-numeric-number 2 "" fix twelve feature
expect base-outside-task 2 "" fix 12 feature --base main
expect reclaim-only-outside-review 2 "" task 7 add-thing --reclaim-only
state "bad-arguments nothing added" 1 "$(git -C "$clone" worktree list --porcelain | grep -c '^worktree ')"

echo "mismatches: $failures"
[ "$failures" -eq 0 ]
