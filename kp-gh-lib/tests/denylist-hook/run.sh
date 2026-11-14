#!/usr/bin/env bash
# Drives .githooks/check-denylist.sh in a mktemp -d git repo against a temp denylist of
# invented terms: no denylist, a content match in another case, a path match and its
# deletion, a removed line, a regex term, an added line starting with `++`, comment and
# blank denylist lines, an invalid regex, a commit message, and a verbose commit's diff
# below the scissors line. Then, end to end, `git commit` through this repo's pre-commit
# and commit-msg hooks in a linked worktree on a task branch. $HOME is an empty
# temp directory and $KP_SKILLS_DENYLIST a temp file, so the operator's own denylist is
# never read. Offline — no GitHub — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/.githooks/check-denylist.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home"
export HOME="$work/home"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export KP_SKILLS_DENYLIST="$work/denylist"
failures=0

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

# run <args…>: runs the script from the fixture repo, leaving its stdout, stderr and exit
# status in $out, $err and $status.
run() {
  out=$(cd "$repo" && "$script" "$@" 2>"$work/stderr")
  status=$?
  err=$(cat "$work/stderr")
  echo "   check-denylist.sh $* -> exit $status${out:+: $out}${err:+ | stderr: $err}"
}

# fresh: a new fixture repo with one committed file, and nothing staged.
fresh() {
  repo="$work/repo-$RANDOM$RANDOM"
  git init -q -b main "$repo"
  printf 'first line\nsecond line\n' >"$repo/notes.txt"
  git -C "$repo" add notes.txt
  git -C "$repo" commit -q -m "Add notes"
}

# has <text>: $err contains it, ignoring case.
has() {
  grep -qiF -- "$1" <<<"$err"
}

fresh
rm -f "$KP_SKILLS_DENYLIST"
printf 'forbiddenco appears here\n' >>"$repo/notes.txt"
git -C "$repo" add notes.txt
run staged
if [ "$status" -eq 0 ] && [ -z "$out$err" ]; then
  check "no denylist" ok
else
  check "no denylist" MISMATCH
fi

printf 'forbiddenco\nsecret-?project\n' >"$KP_SKILLS_DENYLIST"

fresh
printf 'the ForbiddenCo account\n' >>"$repo/notes.txt"
git -C "$repo" add notes.txt
run staged
if [ "$status" -eq 1 ] && has "notes.txt:3: matches denylist line 1" \
  && ! has forbiddenco && ! has account; then
  check "content match, other case" ok
else
  check "content match, other case" MISMATCH
fi

fresh
printf 'harmless\n' >"$repo/forbiddenco-plan.txt"
git -C "$repo" add forbiddenco-plan.txt
run staged
path_status=$status
path_named=no
has "forbiddenco-plan.txt: matches denylist line 1" && path_named=yes
git -C "$repo" commit -q --no-verify -m "Add a file"
git -C "$repo" rm -q forbiddenco-plan.txt
run staged
if [ "$path_status" -eq 1 ] && [ "$path_named" = yes ] && [ "$status" -eq 0 ]; then
  check "path match, then its deletion" ok
else
  check "path match, then its deletion" MISMATCH
fi

fresh
printf 'first line\nforbiddenco\n' >"$repo/notes.txt"
git -C "$repo" add notes.txt
git -C "$repo" commit -q --no-verify -m "Add a term"
printf 'first line\n' >"$repo/notes.txt"
git -C "$repo" add notes.txt
run staged
if [ "$status" -eq 0 ] && [ -z "$err" ]; then
  check "removed line" ok
else
  check "removed line" MISMATCH
fi

fresh
printf 'the secretproject launch\nthe secret-project launch\n' >>"$repo/notes.txt"
git -C "$repo" add notes.txt
run staged
if [ "$status" -eq 1 ] && has "notes.txt:3: matches denylist line 2" \
  && has "notes.txt:4: matches denylist line 2"; then
  check "regex term" ok
else
  check "regex term" MISMATCH
fi

fresh
printf 'harmless\n++ forbiddenco\n' >>"$repo/notes.txt"
git -C "$repo" add notes.txt
run staged
if [ "$status" -eq 1 ] && has "notes.txt:4: matches denylist line 1"; then
  check "added line starting with ++" ok
else
  check "added line starting with ++" MISMATCH
fi

printf '# invented terms\n\nforbiddenco\n' >"$KP_SKILLS_DENYLIST"
fresh
printf '# invented terms\nforbiddenco\n' >>"$repo/notes.txt"
git -C "$repo" add notes.txt
run staged
if [ "$status" -eq 1 ] && has "notes.txt:4: matches denylist line 3" \
  && ! has "notes.txt:3"; then
  check "comment and blank denylist lines" ok
else
  check "comment and blank denylist lines" MISMATCH
fi

printf 'forbiddenco\n(\n' >"$KP_SKILLS_DENYLIST"
fresh
printf 'harmless\n' >>"$repo/notes.txt"
git -C "$repo" add notes.txt
run staged
if [ "$status" -eq 2 ] && has "line 2 of $KP_SKILLS_DENYLIST"; then
  check "invalid regex" ok
else
  check "invalid regex" MISMATCH
fi

printf 'forbiddenco\nsecret-?project\n' >"$KP_SKILLS_DENYLIST"
fresh
printf 'Add notes\nfor ForbiddenCo\n' >"$work/message"
run message "$work/message"
message_status=$status
message_named=no
has "commit message line 2: matches denylist line 1" && ! has forbiddenco && message_named=yes
printf 'Add notes\n# for ForbiddenCo\n' >"$work/message"
run message "$work/message"
if [ "$message_status" -eq 1 ] && [ "$message_named" = yes ] && [ "$status" -eq 0 ]; then
  check "commit message" ok
else
  check "commit message" MISMATCH
fi

printf 'Drop a term\n# ------------------------ >8 ------------------------\n-for ForbiddenCo\n' \
  >"$work/message"
run message "$work/message"
if [ "$status" -eq 0 ] && [ -z "$err" ]; then
  check "verbose message below the scissors line" ok
else
  check "verbose message below the scissors line" MISMATCH
fi

run
bare_status=$status
run message
if [ "$bare_status" -eq 2 ] && [ "$status" -eq 2 ]; then
  check "bad arguments" ok
else
  check "bad arguments" MISMATCH
fi

# End to end: the hooks as git runs them, in a linked worktree on a task branch (what
# pre-commit requires before it reaches the denylist check).
fresh
tree="$work/tree"
git -C "$repo" worktree add -q -b task/1-demo "$tree"
git -C "$tree" config core.hooksPath "$repo_root/.githooks"

# commit <file content> <message>: stages the content and commits; $status is git's.
commit() {
  printf '%s\n' "$1" >"$tree/notes.txt"
  git -C "$tree" add notes.txt
  git -C "$tree" commit -q -m "$2" >"$work/commit-out" 2>&1
  status=$?
  echo "   git commit ($2) -> exit $status"
}

commit "a forbiddenco line" "Add a line"
staged_status=$status
commit "a clean line" "Mention ForbiddenCo"
message_status=$status
commit "a clean line" "Add a clean line"
if [ "$staged_status" -ne 0 ] && [ "$message_status" -ne 0 ] && [ "$status" -eq 0 ] \
  && [ "$(git -C "$tree" log --format=%s -1)" = "Add a clean line" ]; then
  check "git commit through the hooks" ok
else
  cat "$work/commit-out"
  check "git commit through the hooks" MISMATCH
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "all denylist-hook checks passed"
else
  echo "$failures check(s) failed"
fi
exit $(( failures > 0 ? 1 : 0 ))
