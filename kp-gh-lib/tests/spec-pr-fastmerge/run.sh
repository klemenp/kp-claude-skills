#!/usr/bin/env bash
# Drives spec-pr-fastmerge.sh over each case directory against the `gh` and
# spec-pr-check.sh stubs in bin/, which answer from that directory's files and log what
# they were asked to $work/<case>. Compares stdout, the exit code, the posted comment and
# the check order with the case's expected-* files. Offline — no real `gh`, no GitHub —
# so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/spec-pr-fastmerge.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PATH="$here/bin:$PATH"
export KP_GH_LIB_BIN="$here/bin"
failures=0

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

for case_dir in "$here"/*/; do
  name="$(basename "$case_dir")"
  [ "$name" = bin ] && continue
  echo "== $name"
  out="$work/$name"
  mkdir -p "$out"
  args=()
  while IFS= read -r line || [ -n "$line" ]; do
    args+=("$line")
  done < "$case_dir/args"

  actual="$(SPEC_PR_FASTMERGE_CASE="$case_dir" SPEC_PR_FASTMERGE_OUT="$out" \
    "$script" example-org/spec 12 "${args[@]}" 2>"$out/stderr")"
  status=$?
  expected_stdout="$(cat "$case_dir/expected-stdout")"
  expected_exit="$(cat "$case_dir/expected-exit")"
  problems=()

  [ "$actual" = "$expected_stdout" ] ||
    problems+=("stdout: expected '$expected_stdout', got '$actual'")
  [ "$status" -eq "$expected_exit" ] || problems+=("exit: expected $expected_exit, got $status")

  if [ -f "$case_dir/expected-comment.md" ]; then
    cmp -s "$case_dir/expected-comment.md" "$out/posted-comment.md" ||
      problems+=("posted comment differs from expected-comment.md")
  elif [ -e "$out/posted-comment.md" ]; then
    problems+=("a comment was posted")
  fi

  if [ -f "$case_dir/expected-check-log" ]; then
    cmp -s "$case_dir/expected-check-log" "$out/check.log" ||
      problems+=("check.log differs from expected-check-log")
  elif [ "$expected_exit" -eq 2 ] || [ "$name" = read-gap ]; then
    [ -e "$out/check.log" ] && problems+=("spec-pr-check.sh was called")
    [ -e "$out/gh.log" ] && problems+=("gh was called")
  fi

  if [ "${#problems[@]}" -eq 0 ]; then
    check "$name" ok
  else
    printf '%s\n' "${problems[@]}"
    [ -s "$out/stderr" ] && sed 's/^/stderr: /' "$out/stderr"
    check "$name" MISMATCH
  fi
done

echo
if [ "$failures" -eq 0 ]; then
  echo "all spec-pr-fastmerge checks passed"
else
  echo "$failures check(s) failed"
fi
exit $(( failures > 0 ? 1 : 0 ))
