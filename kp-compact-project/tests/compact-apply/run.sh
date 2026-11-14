#!/usr/bin/env bash
# Runs compact-apply.sh against throwaway repos — a bare `origin` and a clone of it per
# case, real git — with the fake `gh` in bin/ on PATH, checking each call's stdout, its
# exit code and the state it leaves: refs in the clone and in origin, the branch the clone
# is on, and a clean work tree after every rollback. Offline: git only, no network.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../../scripts/compact-apply.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The fixture's commits must not depend on the operator's git config (signing, hooks,
# identity), and must not pick up the kp-skills repo's own hooks.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export PATH="$here/bin:$PATH"
export FAKE_GH_LOG="$work/gh.log"

TAG=pre-compaction-2026-01-01
BRANCH=docs/compact-2026-01-01
PR_URL=https://github.com/o/r/pull/1
failures=0
case_number=0
origin="" clone="" base=""

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

# check_true <label> <command…> — ok when the command succeeds.
check_true() {
  local label=$1
  shift
  if "$@"; then check "$label" ok; else check "$label" FAILED; fi
}

# fresh_repo — a new bare origin on `main` with one commit, and a clone of it (origin/HEAD
# set by the clone) as $clone; $base is that commit.
fresh_repo() {
  case_number=$((case_number + 1))
  origin="$work/$case_number/origin.git"
  clone="$work/$case_number/clone"
  git init -q --bare -b main "$origin"
  git clone -q "$origin" "$clone" 2>/dev/null
  git -C "$clone" symbolic-ref HEAD refs/heads/main
  echo seed >"$clone/README.md"
  git -C "$clone" add README.md
  git -C "$clone" commit -qm seed
  git -C "$clone" push -q origin main
  git -C "$clone" remote set-head origin main
  base="$(git -C "$clone" rev-parse HEAD)"
}

# expect <label> <want-exit> <want-stdout> <compact-apply.sh args…>
expect() {
  local label=$1 want_exit=$2 want_stdout=$3
  shift 3
  local stdout exit_code
  echo "== $label"
  stdout="$("$script" "$@" 2>"$work/stderr")"
  exit_code=$?
  if [ "$exit_code" -eq "$want_exit" ]; then
    check "$label exit" ok
  else
    check "$label exit" "exit $exit_code, want $want_exit ($(head -n 1 "$work/stderr"))"
  fi
  # Command substitution drops stdout's trailing newline, so drop the expected one too.
  if diff -u <(printf '%s' "${want_stdout%$'\n'}") <(printf '%s' "$stdout"); then
    check "$label stdout" ok
  else
    check "$label stdout" MISMATCH
  fi
}

has_ref() { git -C "$1" show-ref --verify --quiet "$2"; }
lacks_ref() { ! has_ref "$1" "$2"; }
on_branch() { [ "$(git -C "$clone" rev-parse --abbrev-ref HEAD)" = "$1" ]; }
is_clean() { [ -z "$(git -C "$clone" status --porcelain)" ]; }

# rolled_back <label> — the clone is on main, clean, and holds neither the branch nor the tag.
rolled_back() {
  check_true "$1 on main" on_branch main
  check_true "$1 clean" is_clean
  check_true "$1 no local branch" lacks_ref "$clone" "refs/heads/$BRANCH"
  check_true "$1 no local tag" lacks_ref "$clone" "refs/tags/$TAG"
}

# ready_to_land — prepare and branch on a fresh repo, then write one document.
ready_to_land() {
  fresh_repo
  "$script" prepare "$clone" --tag "$TAG" >/dev/null
  "$script" branch "$clone" --branch "$BRANCH" >/dev/null
  echo "state zero" >"$clone/CLAUDE.md"
}

printf 'docs: compact project state (pre-compaction tag: %s)\n\nDeleted: NOTES.md\n' \
  "$TAG" >"$work/message.txt"
printf 'Tag: %s\n' "$TAG" >"$work/pr-body.md"
# land <label> <want-exit> <want-stdout> — `land` with every argument a real run passes.
land() {
  expect "$@" land "$clone" --branch "$BRANCH" --default main --tag "$TAG" \
    --message-file "$work/message.txt" --title "Compact project docs to state zero" \
    --pr-body-file "$work/pr-body.md"
}

# --- prepare ---------------------------------------------------------------------------

fresh_repo
expect prepare-clean 0 "default main
base $base
tag created
" prepare "$clone" --tag "$TAG"
check_true "prepare-clean tag at base" \
  test "$(git -C "$clone" rev-parse "refs/tags/$TAG^{commit}")" = "$base"

expect prepare-again 0 "default main
base $base
tag reused
" prepare "$clone" --tag "$TAG"

fresh_repo
first="$base"
echo more >>"$clone/README.md"
git -C "$clone" commit -qam second
git -C "$clone" tag "$TAG" "$first"
git -C "$clone" push -q origin main
expect prepare-tag-elsewhere 3 "default main
base $(git -C "$clone" rev-parse HEAD)
stop tag-elsewhere $first
" prepare "$clone" --tag "$TAG"

fresh_repo
expect prepare-no-tag 0 "default main
base $base
tag skipped
" prepare "$clone" --tag "$TAG" --no-tag
check_true "prepare-no-tag no tag ref" lacks_ref "$clone" "refs/tags/$TAG"

fresh_repo
touch "$clone/untracked.md"
expect prepare-dirty 3 "stop dirty
" prepare "$clone" --tag "$TAG"

fresh_repo
git -C "$clone" switch -q -c feature
expect prepare-not-on-default 3 "stop not-on-default feature
" prepare "$clone" --tag "$TAG"

fresh_repo
echo local >>"$clone/README.md"
git -C "$clone" commit -qam local
expect prepare-diverged 3 "stop diverged $(git -C "$clone" rev-parse HEAD) $base
" prepare "$clone" --tag "$TAG"

# --- branch ----------------------------------------------------------------------------

fresh_repo
git -C "$origin" branch "$BRANCH" main
git -C "$clone" fetch -q origin
expect branch-exists 3 "stop branch-exists $BRANCH
" branch "$clone" --branch "$BRANCH"
check_true "branch-exists still on main" on_branch main

# --- land ------------------------------------------------------------------------------

ready_to_land
: >"$FAKE_GH_LOG"
land land-success 0 "pushed $BRANCH
pushed $TAG
pr $PR_URL
"
check_true "land-success branch in origin" has_ref "$origin" "refs/heads/$BRANCH"
check_true "land-success tag in origin" has_ref "$origin" "refs/tags/$TAG"
check_true "land-success gh pr create args" grep -qx \
  "pr create --base main --head $BRANCH --title Compact project docs to state zero --body-file $work/pr-body.md" \
  "$FAKE_GH_LOG"

ready_to_land
mkdir "$clone/.fixture-hooks"
printf '#!/bin/sh\necho "commits need a task/<n>-<slug> branch" >&2\nexit 1\n' \
  >"$clone/.fixture-hooks/pre-commit"
chmod +x "$clone/.fixture-hooks/pre-commit"
git -C "$clone" config core.hooksPath "$clone/.fixture-hooks"
# The hooks dir is the fixture's, not the change's: keep it out of `add -A`.
echo ".fixture-hooks/" >>"$clone/.git/info/exclude"
land land-hook-rejected 3 "rejected commits need a task/<n>-<slug> branch
"
rolled_back land-hook-rejected
check_true "land-hook-rejected no branch in origin" lacks_ref "$origin" "refs/heads/$BRANCH"
check_true "land-hook-rejected no tag in origin" lacks_ref "$origin" "refs/tags/$TAG"

fresh_repo
"$script" prepare "$clone" --tag "$TAG" >/dev/null
"$script" branch "$clone" --branch "$BRANCH" >/dev/null
land land-nothing-staged 1 "failed commit nothing staged
"
rolled_back land-nothing-staged

ready_to_land
export FAKE_GH_FAIL=1
land land-pr-failed 1 "pushed $BRANCH
pushed $TAG
failed pr
"
unset FAKE_GH_FAIL
rolled_back land-pr-failed

ready_to_land
head_before="$(git -C "$clone" rev-parse HEAD)"
expect land-missing-title 2 "" land "$clone" --branch "$BRANCH" --default main --tag "$TAG" \
  --message-file "$work/message.txt" --pr-body-file "$work/pr-body.md"
check_true "land-missing-title still on branch" on_branch "$BRANCH"
check_true "land-missing-title HEAD unchanged" \
  test "$(git -C "$clone" rev-parse HEAD)" = "$head_before"
check_true "land-missing-title nothing staged" git -C "$clone" diff --cached --quiet
check_true "land-missing-title tag kept" has_ref "$clone" "refs/tags/$TAG"

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
