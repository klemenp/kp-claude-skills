#!/usr/bin/env bash
# Drives research-prs.sh over each case directory against the `gh` stub in bin/. A case
# holds pr-list.json (absent: the list call fails), an optional board-fail (content ids
# whose board add fails), expected.json (stdout, compared with `jq -S`; absent for a
# non-zero exit), an optional expected-exit (default 0), an optional expected-stderr (a
# substring stderr must carry) and an optional args file (one invocation per line;
# default `owner/repo 7 --project-id PVT_1`). Offline — no real `gh`, no GitHub — so this
# runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/research-prs.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PATH="$here/bin:$PATH"
DEFAULT_ARGS="owner/repo 7 --project-id PVT_1"
mismatches=0

mismatch() {
  echo "MISMATCH $1: $2"
  mismatches=$((mismatches + 1))
}

run_case() {
  local case_dir=$1 name=$2 args_line=$3 expected_exit=0 status
  local -a args
  read -ra args <<<"$args_line"
  [ -f "$case_dir/expected-exit" ] && expected_exit=$(cat "$case_dir/expected-exit")
  RESEARCH_PRS_CASE="$case_dir" "$script" "${args[@]}" >"$work/out" 2>"$work/err"
  status=$?
  if [ "$status" -ne "$expected_exit" ]; then
    mismatch "$name" "\`$args_line\` exited $status, expected $expected_exit: $(cat "$work/err")"
    return
  fi
  if [ -f "$case_dir/expected.json" ] \
    && ! diff <(jq -S . "$case_dir/expected.json") <(jq -S . "$work/out" 2>&1); then
    mismatch "$name" "stdout differs from expected.json"
  fi
  if [ -f "$case_dir/expected-stderr" ] \
    && ! grep -qF "$(cat "$case_dir/expected-stderr")" "$work/err"; then
    mismatch "$name" "stderr lacks \"$(cat "$case_dir/expected-stderr")\": $(cat "$work/err")"
  fi
}

for case_dir in "$here"/*/; do
  name="$(basename "$case_dir")"
  [ "$name" = bin ] && continue
  echo "== $name"
  if [ -f "$case_dir/args" ]; then
    while IFS= read -r args_line; do
      run_case "$case_dir" "$name" "$args_line"
    done <"$case_dir/args"
  else
    run_case "$case_dir" "$name" "$DEFAULT_ARGS"
  fi
done

echo "mismatches: $mismatches"
[ "$mismatches" -eq 0 ]
