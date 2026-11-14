#!/usr/bin/env bash
# Runs ensure-checkout.sh against throwaway repos: bare repos under <tmp>/remote stand in
# for GitHub (a GIT_CONFIG_GLOBAL `insteadOf` maps https://github.com/o/ onto them, so the
# real fetch runs offline), a primary clone whose raw origin is
# https://github.com/o/demo.git, and a linked worktree of it. bin/gh fakes
# `gh repo clone`. Offline, so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/ensure-checkout.sh"
failures=0

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

# expect <label> <exit> <path|-> [<arg>…] — runs the script from the current directory;
# on an expected exit 0 the printed path must equal <path>.
expect() {
  local label=$1 want_exit=$2 want_path=$3 got_path status=0
  shift 3
  got_path=$("$script" "$@" 2>/dev/null) || status=$?
  if [ "$status" -ne "$want_exit" ]; then
    echo "   exit $status, want $want_exit"
    check "$label" MISMATCH
  elif [ "$want_exit" -eq 0 ] && [ "$got_path" != "$want_path" ]; then
    echo "   printed '$got_path', want '$want_path'"
    check "$label" MISMATCH
  else
    check "$label" ok
  fi
}

# expect_stderr <label> <pattern> -- <arg>… — runs the script from the current directory
# with stderr captured; it must exit 0 and its stderr match <pattern> (`grep -q`), or be
# empty when <pattern> is the literal EMPTY.
expect_stderr() {
  local label=$1 pattern=$2 status=0
  shift 3
  "$script" "$@" >/dev/null 2>"$tmp/stderr" || status=$?
  if [ "$status" -ne 0 ]; then
    echo "   exit $status, want 0"
    check "$label" MISMATCH
  elif [ "$pattern" = EMPTY ] && [ -s "$tmp/stderr" ]; then
    echo "   stderr: $(cat "$tmp/stderr"), want none"
    check "$label" MISMATCH
  elif [ "$pattern" != EMPTY ] && ! grep -q "$pattern" "$tmp/stderr"; then
    echo "   stderr: $(cat "$tmp/stderr"), want '$pattern'"
    check "$label" MISMATCH
  else
    check "$label" ok
  fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tmp=$(cd "$tmp" && pwd -P)

export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --file "$GIT_CONFIG_GLOBAL" user.name fixture
git config --file "$GIT_CONFIG_GLOBAL" user.email fixture@example.invalid
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" "url.$tmp/remote/.insteadOf" https://github.com/o/
export PATH="$here/bin:$PATH"

# A seed repo pushes `main` to the bare demo.git; it also pushes the branches the fetch
# scenarios look for, so the clone's own remote-tracking refs stay untouched.
mkdir -p "$tmp/remote" "$tmp/ws"
git init -q --bare "$tmp/remote/demo.git"
git init -q "$tmp/seed"
git -C "$tmp/seed" commit -q --allow-empty -m seed
git -C "$tmp/seed" push -q "$tmp/remote/demo.git" main
git clone -q --bare "$tmp/remote/demo.git" "$tmp/remote/missing.git"
git clone -q https://github.com/o/demo.git "$tmp/ws/demo"
git clone -q https://github.com/o/demo.git "$tmp/ws/other"
git -C "$tmp/ws/demo" worktree add -q "$tmp/demo-worktree"
mkdir -p "$tmp/ws/demo/sub" "$tmp/nested/plain"
git init -q "$tmp/nested"

has_ref() { git -C "$tmp/ws/demo" rev-parse --verify -q "refs/remotes/origin/$1" >/dev/null; }

echo "== 1 primary clone, fetched"
git -C "$tmp/seed" push -q "$tmp/remote/demo.git" main:feature-one
expect "prints the clone" 0 "$tmp/ws/demo" o/demo --workspace "$tmp/ws"
if has_ref feature-one; then check "fetch brought origin/feature-one" ok; else check "fetch brought origin/feature-one" MISMATCH; fi

echo "== 2 --no-fetch"
git -C "$tmp/seed" push -q "$tmp/remote/demo.git" main:feature-two
expect "prints the clone" 0 "$tmp/ws/demo" o/demo --workspace "$tmp/ws" --no-fetch
if has_ref feature-two; then check "origin/feature-two not fetched" MISMATCH; else check "origin/feature-two not fetched" ok; fi

echo "== 3 missing checkout"
expect "missing without --clone exits 5" 5 - o/missing --workspace "$tmp/ws"
expect "missing with --clone is cloned" 0 "$tmp/ws/missing" o/missing --workspace "$tmp/ws" --clone
if [ -d "$tmp/ws/missing/.git" ]; then check "clone has a .git directory" ok; else check "clone has a .git directory" MISMATCH; fi

echo "== 4 origin names another repo"
expect "origin mismatch exits 5" 5 - o/other --workspace "$tmp/ws"

echo "== 5 --here"
cd "$tmp/demo-worktree" || exit 1
expect "worktree exits 5" 5 - --here --no-fetch
cd "$tmp/ws/demo/sub" || exit 1
expect "subdirectory prints the clone root" 0 "$tmp/ws/demo" --here --no-fetch
cd "$here" || exit 1

echo "== 6 plain directory inside another repo"
expect "nested plain directory exits 5" 5 - o/plain --workspace "$tmp/nested"

echo "== 7 bad arguments"
expect "--here with a repo exits 2" 2 - --here o/demo
expect "--clone with --here exits 2" 2 - --clone --here
expect "no arguments exits 2" 2 -

echo "== 8 not-clean warning"
demo=(o/demo --workspace "$tmp/ws" --no-fetch)
expect_stderr "clean checkout is silent" EMPTY -- "${demo[@]}"
touch "$tmp/ws/demo/untracked.txt"
expect_stderr "dirty checkout warns" 'not clean (local changes)' -- "${demo[@]}"
expect "dirty checkout still prints the clone" 0 "$tmp/ws/demo" "${demo[@]}"
rm "$tmp/ws/demo/untracked.txt"
git -C "$tmp/ws/demo" switch -q -c side
expect_stderr "off-branch checkout warns" 'not clean (on side, not main)' -- "${demo[@]}"
git -C "$tmp/ws/demo" switch -q --detach
expect_stderr "detached checkout warns" 'not clean (on a detached HEAD, not main)' -- "${demo[@]}"
git -C "$tmp/ws/demo" switch -q main

echo "mismatches: $failures"
[ "$failures" -eq 0 ]
