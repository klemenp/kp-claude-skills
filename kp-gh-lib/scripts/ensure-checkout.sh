#!/usr/bin/env bash
# Resolve a repo's primary checkout, guard it and fetch it, then print its path — the
# launch and per-repo checkout step `kp-do-gh-task-loop`, `kp-do-gh-pr-loop`,
# `kp-do-gh-pr-loop-all` and `kp-do-gh-ready-items` each used to spell out in prose.
#
# Usage: ensure-checkout.sh (<owner/name> --workspace <dir> [--clone] | --here) [--no-fetch]
#
#   <owner/name> --workspace <dir>
#           The checkout is <dir>/<name>. When it does not exist: with --clone it is
#           `gh repo clone`d there (bounded by CLONE_TIMEOUT_SECONDS); without, exit 5.
#           Its raw `remote.origin.url` (not `git remote get-url`, which applies
#           `insteadOf` rewrites), with `git@host:` read as `host/` and a trailing `/` and
#           `.git` stripped, must end in /<owner>/<name>, compared case-insensitively.
#   --here  The checkout is the top level of the current directory's work tree. No
#           origin check: the caller does not know its repo yet (preamble.sh checks it).
#
# Both modes then require the checkout to be its own work tree's top level (a plain
# directory nested in another repo is not a checkout) and a primary checkout, never a
# linked worktree: its `git rev-parse --git-common-dir` must be its own `.git` directory.
# Unless --no-fetch, `git fetch origin --prune` runs (bounded by GIT_TIMEOUT_SECONDS).
# On success prints the checkout's absolute physical path, one line. When the checkout is
# not clean — `git status --porcelain` is non-empty, or HEAD is not on the default branch
# (`refs/remotes/origin/HEAD`; that half is skipped when the ref is unset, never asking
# `gh`) — one stderr line comes first:
#   ensure-checkout.sh: <path>: not clean (<reason>) — fresh reads are exported, not pulled
# where <reason> is `local changes`, `on <branch>, not <default>` or `on a detached HEAD,
# not <default>`, two joined by `; `. `kp-do-gh-ready-items` notifies on it; other callers
# ignore it.
#
# Exit: 0 path printed (with or without the not-clean warning) · 1 clone or fetch failure ·
# 2 bad arguments · 5 not a usable primary checkout (missing without --clone, not a git
# checkout, a worktree, origin mismatch) — the same code as preamble.sh's guard.
set -euo pipefail

GIT_TIMEOUT_SECONDS=60
CLONE_TIMEOUT_SECONDS=600
EXIT_UNUSABLE=5

usage() {
  echo "usage: ensure-checkout.sh (<owner/name> --workspace <dir> [--clone] | --here) [--no-fetch]" >&2
  exit 2
}

repo="" workspace="" clone=false here=false fetch=true
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) [ $# -ge 2 ] || usage; workspace=$2; shift 2 ;;
    --clone) clone=true; shift ;;
    --here) here=true; shift ;;
    --no-fetch) fetch=false; shift ;;
    -*) usage ;;
    *) [ -z "$repo" ] || usage; repo=$1; shift ;;
  esac
done

if $here; then
  if [ -n "$repo" ] || [ -n "$workspace" ] || $clone; then usage; fi
else
  if [ -z "$repo" ] || [ -z "$workspace" ]; then usage; fi
  [[ "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || usage
fi

fail() {
  printf 'ensure-checkout.sh: %s\n' "$1" >&2
  exit 1
}

unusable() {
  printf 'ensure-checkout.sh: %s\n' "$1" >&2
  exit "$EXIT_UNUSABLE"
}

# `timeout(1)` is not in base macOS, so network calls are bounded by a watchdog instead
# (the fresh-checkout.sh pattern). Its own output goes to /dev/null so it cannot hold a
# command substitution open after the call returns.
run_bounded() {
  local seconds=$1 pid killer code=0
  shift
  "$@" &
  pid=$!
  ( sleep "$seconds"; kill -TERM "$pid" ) >/dev/null 2>&1 &
  killer=$!
  wait "$pid" || code=$?
  kill -TERM "$killer" >/dev/null 2>&1 || true
  return "$code"
}

if $here; then
  checkout=$(git rev-parse --show-toplevel 2>/dev/null) \
    || unusable "$(pwd): not inside a git checkout"
else
  checkout="${workspace%/}/${repo#*/}"
  if [ ! -e "$checkout" ]; then
    $clone || unusable "$checkout: missing"
    if ! output=$(run_bounded "$CLONE_TIMEOUT_SECONDS" gh repo clone "$repo" "$checkout" 2>&1); then
      fail "gh repo clone $repo $checkout failed: ${output:-timed out after ${CLONE_TIMEOUT_SECONDS}s}"
    fi
  fi
fi

physical=$(cd "$checkout" 2>/dev/null && pwd -P) || unusable "$checkout: not a git checkout"
toplevel=$(git -C "$physical" rev-parse --show-toplevel 2>/dev/null) \
  || unusable "$checkout: not a git checkout"
[ "$(cd "$toplevel" && pwd -P)" = "$physical" ] || unusable "$checkout: not a git checkout"

# In a linked worktree `.git` is a file, so the second `cd` fails.
common_dir=$(cd "$physical" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
own_git_dir=$(cd "$physical/.git" 2>/dev/null && pwd -P) || own_git_dir=""
[ "$common_dir" = "$own_git_dir" ] \
  || unusable "$checkout: a worktree of $common_dir, not a primary checkout"

if ! $here; then
  origin_url=$(git -C "$physical" config --get remote.origin.url || true)
  normalized=$(printf '%s' "$origin_url" | sed -E 's#^[^/@]+@([^:/]+):#\1/#; s#/+$##; s#\.git$##' \
    | tr '[:upper:]' '[:lower:]')
  wanted=$(printf '/%s' "$repo" | tr '[:upper:]' '[:lower:]')
  case "$normalized" in
    *"$wanted") ;;
    *) unusable "$checkout: origin is ${origin_url:-<none>}, not $repo" ;;
  esac
fi

if $fetch; then
  if ! output=$(run_bounded "$GIT_TIMEOUT_SECONDS" git -C "$physical" fetch origin --prune 2>&1); then
    fail "$checkout: git fetch origin --prune failed: ${output:-timed out after ${GIT_TIMEOUT_SECONDS}s}"
  fi
fi

# A dirty or off-branch checkout cannot be pulled, so fresh-checkout.sh exports a worktree
# on every read of it; say so once here so a caller can tell the operator.
reasons=()
[ -z "$(git -C "$physical" status --porcelain)" ] || reasons+=("local changes")
if default_ref=$(git -C "$physical" symbolic-ref --short -q refs/remotes/origin/HEAD); then
  default_branch=${default_ref#origin/}
  current_branch=$(git -C "$physical" symbolic-ref --short -q HEAD || true)
  if [ -z "$current_branch" ]; then
    reasons+=("on a detached HEAD, not $default_branch")
  elif [ "$current_branch" != "$default_branch" ]; then
    reasons+=("on $current_branch, not $default_branch")
  fi
fi
if [ ${#reasons[@]} -gt 0 ]; then
  joined=$(printf '; %s' "${reasons[@]}")
  printf 'ensure-checkout.sh: %s: not clean (%s) — fresh reads are exported, not pulled\n' \
    "$physical" "${joined#; }" >&2
fi

printf '%s\n' "$physical"
