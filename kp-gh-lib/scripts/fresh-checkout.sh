#!/usr/bin/env bash
# Print one directory holding the current `origin/<default branch>` code of a local
# clone, so a skill that reads a checkout (`--code-root`) never judges stale code.
#
# Usage: fresh-checkout.sh <path> [--ref <branch>]
#
# Fetches origin, then, with `--ref <branch>` (a milestone branch such as `release/M<k>`)
# naming a branch other than the default one:
#   - `origin/<branch>` resolves to a commit → the clone is never touched (not pulled, not
#     checked out): `origin/<branch>` is exported as below and its path printed, with no
#     stderr note;
#   - it does not → one stderr line `fresh-checkout.sh: origin/<branch> not found; reading
#     origin/<default>` and the default-branch behaviour below, unchanged.
# A `--ref` naming the default branch, or no `--ref`, reads the default branch:
#   - the clone is on its default branch with a clean work tree and `git pull --ff-only`
#     brings it to `origin/<default branch>` → prints <path>;
#   - otherwise (local edits, another branch, a diverged branch or unpushed commits) the
#     clone is never touched: `origin/<default branch>` is exported as a detached worktree
#     at `${TMPDIR:-/tmp}/kp-fresh-<repo-name>-<short-sha>`, reused when it already exists
#     at that SHA, its path is printed, and one stderr line names why the clone was not
#     pulled.
# Stale exports are evicted on every successful call, pulled or exported, just before the
# path is printed: after the fetch `git worktree prune` drops this clone's registrations
# whose directory is gone (silently — so a vanished export at the current SHA is simply
# re-added), and then every worktree of this clone named `kp-fresh-<repo-name>-*` whose
# HEAD is the tip of no `refs/remotes/origin/*` branch is `git worktree remove`d (no
# `--force`). The export at the current `origin/<default>` and one at a live
# `origin/release/M<k>` tip survive. One that refuses (local changes in it) is kept and
# named in one stderr line `fresh-checkout.sh: kept <path>: <git's message>` on every call
# while it stays dirty. Eviction never changes the exit code or the printed path, and only
# this clone's registered worktrees are touched — never a directory globbed from $TMPDIR.
# Accepted race: a concurrent skill reading a now-stale export of this clone — including one
# another clone of the same repo name reused at the same SHA — loses it mid-read and fails
# that read; its next call here recreates the current one.
#
# Exit: 0 a directory was printed · 1 a fetch or git failure · 2 bad arguments (including a
# `--ref` that fails `git check-ref-format --branch` or holds a character outside
# `[A-Za-z0-9._/-]`).
set -euo pipefail

GIT_TIMEOUT_SECONDS=60

usage() {
  echo "usage: fresh-checkout.sh <path> [--ref <branch>]" >&2
  exit 2
}

clone=""
ref=""
while [ $# -gt 0 ]; do
  case $1 in
    --ref)
      [ $# -ge 2 ] || usage
      ref=$2
      shift 2
      ;;
    -*) usage ;;
    *)
      [ -z "$clone" ] || usage
      clone=$1
      shift
      ;;
  esac
done
[ -n "$clone" ] && [ -d "$clone" ] || usage
if [ -n "$ref" ]; then
  [[ $ref =~ ^[A-Za-z0-9._/-]+$ ]] || usage
  git check-ref-format --branch "$ref" >/dev/null 2>&1 || usage
fi

fail() {
  printf 'fresh-checkout.sh: %s: %s\n' "$clone" "$1" >&2
  exit 1
}

# Remove this clone's `kp-fresh-<repo_name>-*` worktrees whose HEAD no origin branch
# points to any more. Best-effort: a refused remove is one stderr line, never a failure.
evict_stale_exports() {
  local live_tips listing line path="" head_sha message
  live_tips=$(git -C "$clone" for-each-ref --format='%(objectname)' refs/remotes/origin/) || return 0
  listing=$(git -C "$clone" worktree list --porcelain) || return 0
  while IFS= read -r line; do
    case $line in
      "worktree "*) path=${line#worktree } ;;
      "HEAD "*)
        head_sha=${line#HEAD }
        case $(basename "$path") in
          "kp-fresh-$repo_name-"*) ;;
          *) continue ;;
        esac
        grep -qxF "$head_sha" <<<"$live_tips" && continue
        if ! message=$(git -C "$clone" worktree remove "$path" 2>&1); then
          printf 'fresh-checkout.sh: kept %s: %s\n' "$path" "$(head -n 1 <<<"$message")" >&2
        fi
        ;;
    esac
  done <<<"$listing"
}

# `timeout(1)` is not in base macOS, so network calls are bounded by a watchdog instead
# (the set-status.sh pattern). Its own output goes to /dev/null so it cannot hold a
# command substitution open after the call returns.
run_bounded() {
  local pid killer code=0
  "$@" &
  pid=$!
  ( sleep "$GIT_TIMEOUT_SECONDS"; kill -TERM "$pid" ) >/dev/null 2>&1 &
  killer=$!
  wait "$pid" || code=$?
  kill -TERM "$killer" >/dev/null 2>&1 || true
  return "$code"
}

git -C "$clone" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "not a git work tree"

if ! output=$(run_bounded git -C "$clone" fetch origin 2>&1); then
  fail "git fetch origin failed: ${output:-timed out after ${GIT_TIMEOUT_SECONDS}s}"
fi

# Drop registrations whose directory is gone, before anything reuses or re-adds one.
git -C "$clone" worktree prune >/dev/null 2>&1 || true
repo_name=$(basename -s .git "$(git -C "$clone" remote get-url origin)")

# Bare default branch, as kp-sync-spec-tasks §0.9 resolves it.
if head_ref=$(git -C "$clone" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null); then
  default_branch=${head_ref#refs/remotes/origin/}
elif ! default_branch=$(cd "$clone" && run_bounded gh repo view --json defaultBranchRef \
  -q .defaultBranchRef.name 2>&1); then
  fail "cannot resolve the default branch: ${default_branch:-timed out after ${GIT_TIMEOUT_SECONDS}s}"
fi
[ -n "$default_branch" ] || fail "cannot resolve the default branch"

# The branch whose code is printed: the --ref when origin has it, else the default.
read_branch=$default_branch
if [ -n "$ref" ] && [ "$ref" != "$default_branch" ]; then
  if git -C "$clone" rev-parse --verify -q "origin/$ref^{commit}" >/dev/null; then
    read_branch=$ref
  else
    printf 'fresh-checkout.sh: origin/%s not found; reading origin/%s\n' "$ref" "$default_branch" >&2
  fi
fi

origin_sha=$(git -C "$clone" rev-parse --verify -q "origin/$read_branch^{commit}") \
  || fail "origin/$read_branch does not exist after fetch"

current_branch=$(git -C "$clone" symbolic-ref --short -q HEAD || true)
if [ "$read_branch" != "$default_branch" ]; then
  # A milestone branch is always exported: the clone stays on its default branch.
  reason=""
elif [ "$current_branch" != "$default_branch" ]; then
  reason="on ${current_branch:-a detached HEAD}, not $default_branch"
elif [ -n "$(git -C "$clone" status --porcelain)" ]; then
  reason="the work tree has local changes"
elif ! output=$(run_bounded git -C "$clone" pull --ff-only origin "$default_branch" 2>&1); then
  reason="git pull --ff-only failed: ${output:-timed out after ${GIT_TIMEOUT_SECONDS}s}"
elif [ "$(git -C "$clone" rev-parse HEAD)" != "$origin_sha" ]; then
  reason="$default_branch has commits not on origin/$default_branch"
else
  evict_stale_exports
  printf '%s\n' "$clone"
  exit 0
fi

short_sha=$(git -C "$clone" rev-parse --short "$origin_sha")
export_dir="${TMPDIR:-/tmp}"
export_dir="${export_dir%/}/kp-fresh-$repo_name-$short_sha"

if [ -d "$export_dir" ]; then
  [ "$(git -C "$export_dir" rev-parse HEAD 2>/dev/null)" = "$origin_sha" ] \
    || fail "$export_dir exists but is not a checkout of origin/$read_branch ($short_sha)"
elif ! output=$(git -C "$clone" worktree add --detach "$export_dir" "origin/$read_branch" 2>&1); then
  fail "git worktree add failed: $output"
fi

if [ -n "$reason" ]; then
  printf 'fresh-checkout.sh: %s not pulled (%s); exported origin/%s to %s\n' \
    "$clone" "$reason" "$default_branch" "$export_dir" >&2
fi
evict_stale_exports
printf '%s\n' "$export_dir"
