#!/usr/bin/env bash
# Drives link-item.sh against the fakes in bin/ (gh on PATH, item-id.sh through
# KP_GH_LIB_BIN): each case sets the FAKE_* knobs that pick one rung of the sub-issue
# ladder or one failure, then checks the exit code, the printed `via` / `boardItem` and
# the calls logged. Offline — no GitHub — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/link-item.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PATH="$here/bin:$PATH" KP_GH_LIB_BIN="$here/bin" FAKE_LOG="$work/calls.log" \
  FAKE_WRITTEN="$work/written.md"
failures=0

parent=example-org/demo#5
child=example-org/demo#9

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

# run_case <name> <exit> <via> <boardItem> [VAR=value …] -- <link-item.sh args…>
# <via> / <boardItem> are the expected JSON values (`null` or a quoted string).
run_case() {
  local name=$1 expected_exit=$2 expected_via=$3 expected_board=$4
  shift 4
  local knobs=()
  while [ "$1" != -- ]; do knobs+=("$1"); shift; done
  shift
  echo "== $name"
  : > "$FAKE_LOG"
  rm -f "$FAKE_WRITTEN"
  local status=0 fields
  output="$(env ${knobs[@]+"${knobs[@]}"} "$script" "$@" 2>"$work/stderr")" || status=$?
  fields="$(jq -c '[.via, .boardItem]' <<<"$output" 2>/dev/null)"
  if [ "$status" -eq "$expected_exit" ] && [ "$fields" = "[$expected_via,$expected_board]" ]; then
    check "$name" ok
  else
    printf 'exit %s, output: %s, stderr: %s\n' "$status" "$output" "$(cat "$work/stderr")"
    check "$name" MISMATCH
  fi
}

# expect_log <label> <present|absent> <grep -E pattern>
expect_log() {
  local label=$1 want=$2 pattern=$3 found=absent
  grep -qE "$pattern" "$FAKE_LOG" && found=present
  if [ "$found" = "$want" ]; then check "$label" ok
  else printf 'calls:\n%s\n' "$(cat "$FAKE_LOG")"; check "$label" MISMATCH; fi
}

# expect_written_tail <label> <expected last line of the written parent body>
expect_written_tail() {
  local label=$1 expected=$2
  if [ -f "$FAKE_WRITTEN" ] && [ "$(tail -n 1 "$FAKE_WRITTEN")" = "$expected" ]; then
    check "$label" ok
  else
    printf 'written body:\n%s\n' "$(cat "$FAKE_WRITTEN" 2>/dev/null)"
    check "$label" MISMATCH
  fi
}

run_case "already under that parent" 0 '"existing"' null FAKE_CHILD_PARENT=$parent -- \
  --parent $parent --child $child
expect_log "existing: no mutation" absent 'link|board-add|issue-edit-body'

run_case "under another parent" 1 null null FAKE_CHILD_PARENT=example-org/demo#6 -- \
  --parent $parent --child $child
if grep -q 'has parent example-org/demo#6' "$work/stderr"; then check "another parent: stderr" ok
else check "another parent: stderr" MISMATCH; fi
expect_log "another parent: no mutation" absent 'link|board-add|issue-edit-body'

run_case "graphql rung" 0 '"graphql"' null -- --parent $parent --child $child
expect_log "graphql: mutation on the two node ids" present '^graphql-link I_5 I_9$'

run_case "native rung" 0 '"native"' null FAKE_NATIVE=1 -- --parent $parent --child $child
expect_log "native: gh issue edit --add-sub-issue" present \
  '^native-link 5 https://github.com/example-org/demo/issues/9$'
expect_log "native: no GraphQL mutation" absent '^graphql-link'

run_case "extension rung" 0 '"extension"' null FAKE_GRAPHQL_FAIL=1 FAKE_EXTENSION=1 -- \
  --parent $parent --child $child
expect_log "extension: gh sub-issue add" present \
  '^extension-link 5 https://github.com/example-org/demo/issues/9$'

run_case "tasklist rung, same repo" 0 '"tasklist"' null FAKE_GRAPHQL_FAIL=1 -- \
  --parent $parent --child $child
expect_written_tail "tasklist: same-repo line appended" '- [ ] #9'

run_case "tasklist rung, different repos" 0 '"tasklist"' null FAKE_GRAPHQL_FAIL=1 -- \
  --parent $parent --child example-org/other#9
expect_written_tail "tasklist: cross-repo line appended" '- [ ] example-org/other#9'

run_case "tasklist rung, child already referenced" 0 '"tasklist"' null FAKE_GRAPHQL_FAIL=1 \
  "FAKE_PARENT_BODY=Children:
- [ ] #9" -- --parent $parent --child $child
expect_log "tasklist: no body write when referenced" absent '^issue-edit-body'

run_case "tasklist rung, only #90 present" 0 '"tasklist"' null FAKE_GRAPHQL_FAIL=1 \
  "FAKE_PARENT_BODY=Children:
- [ ] #90" -- --parent $parent --child $child
expect_written_tail "tasklist: #90 is not #9" '- [ ] #9'

run_case "child already on the board" 0 '"graphql"' '"PVTI_existing"' \
  FAKE_BOARD_ITEM=PVTI_existing -- --parent $parent --child $child --project-id PVT_board
expect_log "on board: no board add" absent '^board-add'

run_case "child off the board" 0 '"graphql"' '"PVTI_new"' -- \
  --parent $parent --child $child --project-id PVT_board
if [ "$(grep -c '^board-add I_9$' "$FAKE_LOG")" = 1 ]; then check "off board: one board add" ok
else printf 'calls:\n%s\n' "$(cat "$FAKE_LOG")"; check "off board: one board add" MISMATCH; fi

run_case "board add failing after a link" 3 '"graphql"' null FAKE_BOARD_FAIL=1 -- \
  --parent $parent --child $child --project-id PVT_board

for bad in "--child $child" "--parent example-org/demo --child $child" \
  "--parent example-org/demo#0 --child $child" "--parent $parent --child $parent" \
  "--parent $parent --child $child --project-id" "--parent $parent --child $child --bogus x"; do
  echo "== usage: $bad"
  : > "$FAKE_LOG"
  status=0
  # Word splitting of $bad into separate arguments is intended.
  # shellcheck disable=SC2086
  output="$("$script" $bad 2>/dev/null)" || status=$?
  if [ "$status" -eq 2 ] && [ -z "$output" ] && [ ! -s "$FAKE_LOG" ]; then
    check "usage: $bad" ok
  else
    printf 'exit %s, output: %s, calls:\n%s\n' "$status" "$output" "$(cat "$FAKE_LOG")"
    check "usage: $bad" MISMATCH
  fi
done

echo "== usage: empty --project-id"
: > "$FAKE_LOG"
status=0
output="$("$script" --parent $parent --child $child --project-id '' 2>/dev/null)" || status=$?
if [ "$status" -eq 2 ] && [ -z "$output" ] && [ ! -s "$FAKE_LOG" ]; then
  check "usage: empty --project-id" ok
else
  check "usage: empty --project-id" MISMATCH
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "all link-item checks passed"
else
  echo "$failures check(s) failed"
fi
exit $(( failures > 0 ? 1 : 0 ))
