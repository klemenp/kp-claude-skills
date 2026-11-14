#!/usr/bin/env bash
# Runs fresh-checkout.sh against throwaway repos. Each case gets a fresh local bare origin
# with `main` and `release/M1` at different commits; the clone's remote.origin.url is a
# GitHub URL redirected to the bare repo with url.<bare>.insteadOf, HOME is a temp dir and
# TMPDIR a per-case one (cases' commits can share SHAs, so a shared TMPDIR would let one
# case reuse another's export), and a `gh` stub that fails when called is first on PATH. Offline, so this
# runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/fresh-checkout.sh"
failures=0

tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/bin/sh
echo "gh stub: unexpected call: $*" >&2
exit 99
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

# new_case <name>: a bare origin and a clone at $clone on main, one commit behind
# origin/main; origin also has release/M1 at a third commit. Sets clone, main_sha
# (origin/main), release_sha (origin/release/M1) and seed_sha (the clone's HEAD), and
# exports TMPDIR as the case's own export dir.
new_case() {
  local dir="$tmp/$1" bare="$tmp/$1/bare/code.git" url=https://github.com/acme/code
  export TMPDIR="$dir/exports"
  mkdir -p "$dir" "$TMPDIR"
  git init -q --bare -b main "$bare"
  git clone -q "$bare" "$dir/code" 2>/dev/null
  echo seed >"$dir/code/README.md"
  git -C "$dir/code" add README.md
  git -C "$dir/code" commit -q -m Seed
  git -C "$dir/code" push -q origin main
  git -C "$dir/code" remote set-head origin main
  git clone -q "$bare" "$dir/other" 2>/dev/null
  echo main >>"$dir/other/README.md"
  git -C "$dir/other" commit -q -am "Advance main"
  git -C "$dir/other" push -q origin main
  git -C "$dir/other" checkout -q -b release/M1 HEAD~1
  echo milestone >"$dir/other/feature.txt"
  git -C "$dir/other" add feature.txt
  git -C "$dir/other" commit -q -m "Milestone work"
  git -C "$dir/other" push -q origin release/M1
  git -C "$dir/code" remote set-url origin "$url"
  git -C "$dir/code" config "url.$bare.insteadOf" "$url"
  clone="$dir/code"
  main_sha=$(git -C "$dir/other" rev-parse main)
  release_sha=$(git -C "$dir/other" rev-parse release/M1)
  seed_sha=$(git -C "$clone" rev-parse HEAD)
}

# run_script <args>…: sets out, err, status.
run_script() {
  status=0
  out=$("$script" "$@" 2>"$tmp/stderr") || status=$?
  err=$(cat "$tmp/stderr")
}

dump() {
  printf 'status=%s\nstdout=%s\nstderr=%s\n' "$status" "$out" "$err"
}

verdict() {
  if [ "$1" -eq 0 ]; then echo ok; else echo MISMATCH; fi
}

clone_untouched() {
  [ "$(git -C "$clone" rev-parse HEAD)" = "$seed_sha" ] \
    && [ "$(git -C "$clone" symbolic-ref --short HEAD)" = main ] \
    && [ -z "$(git -C "$clone" status --porcelain)" ]
}

echo "== ref exists"
new_case ref-exists
run_script "$clone" --ref release/M1
expected_dir="$TMPDIR/kp-fresh-code-$(git -C "$clone" rev-parse --short "$release_sha")"
if [ "$status" -eq 0 ] && [ "$out" = "$expected_dir" ] && [ -z "$err" ] \
  && [ "$(git -C "$out" rev-parse HEAD)" = "$release_sha" ] && clone_untouched; then
  check "ref exists" ok
else
  dump
  check "ref exists" MISMATCH
fi

echo "== ref export reused"
first=$out
run_script "$clone" --ref release/M1
if [ "$status" -eq 0 ] && [ "$out" = "$first" ] && clone_untouched; then
  check "ref export reused" ok
else
  dump
  check "ref export reused" MISMATCH
fi

echo "== ref missing falls back"
new_case ref-missing
run_script "$clone" --ref release/M9
if [ "$status" -eq 0 ] && [ "$out" = "$clone" ] \
  && [ "$err" = "fresh-checkout.sh: origin/release/M9 not found; reading origin/main" ] \
  && [ "$(git -C "$clone" rev-parse HEAD)" = "$main_sha" ]; then
  check "ref missing falls back" ok
else
  dump
  check "ref missing falls back" MISMATCH
fi

echo "== no ref pulls"
new_case no-ref-pulls
run_script "$clone"
if [ "$status" -eq 0 ] && [ "$out" = "$clone" ] && [ -z "$err" ] \
  && [ "$(git -C "$clone" rev-parse HEAD)" = "$main_sha" ]; then
  check "no ref pulls" ok
else
  dump
  check "no ref pulls" MISMATCH
fi

echo "== no ref exports"
new_case no-ref-exports
git -C "$clone" checkout -q -b feature
run_script "$clone"
expected_dir="$TMPDIR/kp-fresh-code-$(git -C "$clone" rev-parse --short "$main_sha")"
expected_err="fresh-checkout.sh: $clone not pulled (on feature, not main); exported origin/main to $expected_dir"
if [ "$status" -eq 0 ] && [ "$out" = "$expected_dir" ] && [ "$err" = "$expected_err" ] \
  && [ "$(git -C "$out" rev-parse HEAD)" = "$main_sha" ]; then
  check "no ref exports" ok
else
  dump
  check "no ref exports" MISMATCH
fi

echo "== ref is default branch"
without_out=$out
without_err=$err
run_script "$clone" --ref main
if [ "$status" -eq 0 ] && [ "$out" = "$without_out" ] && [ "$err" = "$without_err" ]; then
  check "ref is default branch" ok
else
  dump
  check "ref is default branch" MISMATCH
fi

# advance_main <case>: push one more commit to the case's origin/main; sets main_sha.
advance_main() {
  local other="$tmp/$1/other"
  git -C "$other" checkout -q main
  echo more >>"$other/README.md"
  git -C "$other" commit -q -am "Advance main again"
  git -C "$other" push -q origin main
  main_sha=$(git -C "$other" rev-parse main)
}

# listed <path>: the clone's worktree list names <path>.
listed() {
  git -C "$clone" worktree list --porcelain | grep -qxF "worktree $1"
}

# export_once <case>: a fresh case with a dirty clone, read once; sets export_a.
export_once() {
  new_case "$1"
  touch "$clone/untracked.txt"
  run_script "$clone"
  export_a=$out
}

echo "== older export evicted"
export_once older-evicted
advance_main older-evicted
run_script "$clone"
if [ "$status" -eq 0 ] && [ -d "$out" ] && [ "$out" != "$export_a" ] && [ ! -e "$export_a" ] \
  && listed "$out" && ! listed "$export_a"; then
  check "older export evicted" ok
else
  dump
  check "older export evicted" MISMATCH
fi

echo "== milestone export survives"
new_case milestone-survives
touch "$clone/untracked.txt"
run_script "$clone" --ref release/M1
export_r=$out
run_script "$clone"
if [ "$status" -eq 0 ] && [ -d "$export_r" ] && [ -d "$out" ] && [ "$out" != "$export_r" ] \
  && [ "$(git -C "$export_r" rev-parse HEAD)" = "$release_sha" ]; then
  check "milestone export survives" ok
else
  dump
  check "milestone export survives" MISMATCH
fi

echo "== dirty export kept"
export_once dirty-kept
touch "$export_a/scratch.txt"
advance_main dirty-kept
run_script "$clone"
if [ "$status" -eq 0 ] && [ -d "$export_a" ] && [ -d "$out" ] && [ "$out" != "$export_a" ] \
  && grep -qF "fresh-checkout.sh: kept $export_a: " <<<"$err"; then
  check "dirty export kept" ok
else
  dump
  check "dirty export kept" MISMATCH
fi

echo "== vanished export silent"
export_once vanished-silent
rm -r "$export_a"
advance_main vanished-silent
run_script "$clone"
if [ "$status" -eq 0 ] && [ -d "$out" ] && [ "$out" != "$export_a" ] \
  && ! grep -q kept <<<"$err" && ! listed "$export_a"; then
  check "vanished export silent" ok
else
  dump
  check "vanished export silent" MISMATCH
fi

echo "== vanished current export re-added"
export_once vanished-current
rm -r "$export_a"
run_script "$clone"
if [ "$status" -eq 0 ] && [ "$out" = "$export_a" ] && [ -d "$export_a" ] \
  && [ "$(git -C "$export_a" rev-parse HEAD)" = "$main_sha" ]; then
  check "vanished current export re-added" ok
else
  dump
  check "vanished current export re-added" MISMATCH
fi

echo "== pull evicts exports"
export_once pull-evicts
rm "$clone/untracked.txt"
advance_main pull-evicts
run_script "$clone"
if [ "$status" -eq 0 ] && [ "$out" = "$clone" ] && [ ! -e "$export_a" ] \
  && [ "$(git -C "$clone" rev-parse HEAD)" = "$main_sha" ]; then
  check "pull evicts exports" ok
else
  dump
  check "pull evicts exports" MISMATCH
fi

echo "== other clone untouched"
new_case other-untouched
second="$tmp/other-untouched/second"
git clone -q "$tmp/other-untouched/bare/code.git" "$second" 2>/dev/null
touch "$second/untracked.txt"
run_script "$second"
export_s=$out
advance_main other-untouched
touch "$clone/untracked.txt"
run_script "$clone"
if [ "$status" -eq 0 ] && [ -d "$out" ] && [ "$out" != "$export_s" ] && [ -d "$export_s" ] \
  && [[ $(basename "$export_s") == kp-fresh-code-* ]]; then
  check "other clone untouched" ok
else
  dump
  check "other clone untouched" MISMATCH
fi

echo "== bad arguments"
bad=0
usage_line="usage: fresh-checkout.sh <path> [--ref <branch>]"
expect_usage() {
  run_script "$@"
  if [ "$status" -ne 2 ] || [ -n "$out" ] || [ "$err" != "$usage_line" ]; then
    echo "args: $*"
    dump
    bad=1
  fi
}
expect_usage "$clone" --ref
expect_usage --ref
expect_usage "$clone" --bogus
expect_usage "$clone" "$clone"
expect_usage
check "bad arguments" "$(verdict "$bad")"

echo "== invalid ref"
bad=0
for ref in 'bad..ref' 'release/M1;rm' 'with space' '-leading' 'a@{1}'; do
  run_script "$clone" --ref "$ref"
  if [ "$status" -ne 2 ] || [ -n "$out" ] || [ "$err" != "$usage_line" ]; then
    echo "ref: $ref"
    dump
    bad=1
  fi
done
check "invalid ref" "$(verdict "$bad")"

echo "mismatches: $failures"
[ "$failures" -eq 0 ]
