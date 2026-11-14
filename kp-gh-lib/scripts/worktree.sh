#!/usr/bin/env bash
# Name, reuse or reclaim the sibling worktree a task, fix or review run works in. The
# kp-do-gh-task, kp-fix-pr and kp-review-gh-pr skills each described this in prose,
# each with its own reuse, legacy-name and fast-forward rules; this is that procedure.
#
# Usage: worktree.sh task <n> <slug> [--base <branch>]
#        worktree.sh fix <pr> <headRefName>
#        worktree.sh review <pr> <headRefName> [--reclaim-only]
#
# Run from inside the primary checkout. `..` is the parent of its top level and
# <repo-name> is `basename -s .git "$(git remote get-url origin)"`.
#
# task:   path `../<repo-name>-task-<n>`. Reuses it when this checkout's worktree list has
#         it, else reuses the legacy `../task-<n>` when listed, else adds it on a new
#         branch `task/<n>-<slug>` from the base (`--base`, else origin/HEAD, else the
#         current branch), or on that branch when it already exists. No fetch, no
#         fast-forward. For a milestone item kp-do-gh-task fetches and passes its
#         milestone branch as `--base origin/release/M<k>` (milestone-branch.sh).
# fix:    path `../<repo-name>-fix-pr-<pr>`, legacy `../fix-pr-<pr>`, same reuse order. A
#         new one is a real checkout of <headRefName>, never detached. A reused one is
#         fetched, then fast-forwarded to `origin/<headRefName>` only when it holds no
#         commits that origin lacks; otherwise it is left as is (`ffSkipped: true`) —
#         never `pull --ff-only`, which errors when local is ahead.
# review: path `../<repo-name>-review-pr-<pr>`. Always removes it first, and the legacy
#         `../review-pr-<pr>` too (each only when this checkout lists it, so another
#         repo's same-named sibling is left alone), then, unless `--reclaim-only`, adds
#         it detached at `origin/<headRefName>`. Never reuses.
# No mode ever creates a legacy name.
#
# Prints one JSON object:
#   {"path": "<absolute path>" | null, "reused": bool, "legacy": bool, "ffSkipped": bool}
# `path` is null only for `review --reclaim-only`; `reused` and `legacy` are false in
# review mode; `ffSkipped` is true only for a reused fix worktree that was not moved.
#
# Exit: 0 done · 1 a git command failed (stderr names it) · 2 bad arguments.
set -euo pipefail

usage() {
  [ $# -eq 0 ] || echo "worktree.sh: $1" >&2
  sed -n '7,9p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# Runs a git command with its stdout sent to stderr, so this script's stdout stays one
# JSON object; on failure names the command and exits 1.
run_git() {
  if ! git "$@" >&2; then
    echo "worktree.sh: git $* failed" >&2
    exit 1
  fi
}

# Prints a git command's stdout; on failure names the command and exits 1.
read_git() {
  local output
  if ! output="$(git "$@")"; then
    echo "worktree.sh: git $* failed" >&2
    exit 1
  fi
  printf '%s\n' "$output"
}

is_number() {
  [[ $1 =~ ^[0-9]+$ ]]
}

# True when this checkout's worktree list, read once below, has <path>.
is_listed() {
  grep -Fxq "worktree $1" <<<"$worktrees"
}

emit() {
  local path=$1 reused=$2 legacy=$3 ff_skipped=$4
  if [ -z "$path" ]; then
    jq -cn --argjson reused "$reused" --argjson legacy "$legacy" \
      --argjson ffSkipped "$ff_skipped" \
      '{path: null, reused: $reused, legacy: $legacy, ffSkipped: $ffSkipped}'
  else
    jq -cn --arg path "$path" --argjson reused "$reused" --argjson legacy "$legacy" \
      --argjson ffSkipped "$ff_skipped" \
      '{path: $path, reused: $reused, legacy: $legacy, ffSkipped: $ffSkipped}'
  fi
}

[ $# -ge 1 ] || usage "missing mode"
mode=$1
shift
case "$mode" in
  task | fix | review) ;;
  *) usage "unknown mode: $mode" ;;
esac

base=""
reclaim_only=false
positionals=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      [ "$mode" = task ] || usage "--base is only valid in task mode"
      [ $# -ge 2 ] && [ -n "$2" ] || usage "--base needs a branch"
      base=$2
      shift 2
      ;;
    --reclaim-only)
      [ "$mode" = review ] || usage "--reclaim-only is only valid in review mode"
      reclaim_only=true
      shift
      ;;
    -*) usage "unknown option: $1" ;;
    *)
      positionals+=("$1")
      shift
      ;;
  esac
done

[ "${#positionals[@]}" -eq 2 ] || usage "$mode needs exactly two arguments"
number=${positionals[0]}
name=${positionals[1]}
is_number "$number" || usage "not a number: $number"
[ -n "$name" ] || usage "empty $mode argument"

toplevel="$(read_git rev-parse --show-toplevel)"
parent="$(dirname "$toplevel")"
origin_url="$(read_git remote get-url origin)"
repo_name="$(basename -s .git "$origin_url")"
worktrees="$(read_git worktree list --porcelain)"

case "$mode" in
  task)
    path="$parent/$repo_name-task-$number"
    legacy_path="$parent/task-$number"
    branch="task/$number-$name"
    if is_listed "$path"; then
      emit "$path" true false false
      exit 0
    fi
    if is_listed "$legacy_path"; then
      emit "$legacy_path" true true false
      exit 0
    fi
    if [ -z "$base" ]; then
      base="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" ||
        base="$(read_git rev-parse --abbrev-ref HEAD)"
    fi
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      run_git worktree add "$path" "$branch"
    else
      run_git worktree add "$path" -b "$branch" "$base"
    fi
    emit "$path" false false false
    ;;
  fix)
    path="$parent/$repo_name-fix-pr-$number"
    legacy_path="$parent/fix-pr-$number"
    legacy=false
    if ! is_listed "$path"; then
      if ! is_listed "$legacy_path"; then
        run_git worktree add "$path" "$name"
        emit "$path" false false false
        exit 0
      fi
      path=$legacy_path
      legacy=true
    fi
    run_git -C "$path" fetch origin
    ahead="$(read_git -C "$path" rev-list --count "origin/$name..HEAD")"
    if [ "$ahead" != 0 ]; then
      emit "$path" true "$legacy" true
      exit 0
    fi
    run_git -C "$path" merge --ff-only "origin/$name"
    emit "$path" true "$legacy" false
    ;;
  review)
    path="$parent/$repo_name-review-pr-$number"
    legacy_path="$parent/review-pr-$number"
    for stale in "$path" "$legacy_path"; do
      if is_listed "$stale"; then
        run_git worktree remove --force "$stale"
      fi
    done
    if [ "$reclaim_only" = true ]; then
      emit "" false false false
      exit 0
    fi
    run_git worktree add "$path" --detach "origin/$name"
    emit "$path" false false false
    ;;
esac
