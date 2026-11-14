#!/usr/bin/env bash
# Drives epic-convert.sh against the fakes in bin/ (gh on PATH, ensure-labels.sh through
# KP_GH_LIB_BIN): each case serves one issue through FAKE_ISSUE, sets the FAKE_*_FAIL knob
# it needs, then checks the exit code, the printed JSON and the calls in FAKE_LOG.
# Offline — no GitHub — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/epic-convert.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PATH="$here/bin:$PATH" KP_GH_LIB_BIN="$here/bin" FAKE_LOG="$work/calls.log"
mismatches=0
repo=example-org/shop-tools
read_call="api repos/$repo/issues/12"

# issue <title> <label>… — the REST issue JSON the fake gh serves.
issue() {
  local title=$1
  shift
  jq -cn --arg title "$title" '{title: $title, labels: ($ARGS.positional | map({name: .}))}' \
    --args "$@"
}

# convert <VAR=value>… -- <script args>… — runs the script; sets status, output and calls.
convert() {
  local knobs=()
  while [ "$1" != -- ]; do knobs+=("$1"); shift; done
  shift
  : > "$FAKE_LOG"
  status=0
  output="$(env "${knobs[@]}" "$script" "$@" 2>"$work/stderr")" || status=$?
  calls="$(cat "$FAKE_LOG")"
}

# expect <label> <actual> <expected>
expect() {
  if [ "$2" = "$3" ]; then
    echo "-> $1: ok"
  else
    printf -- '-> %s: MISMATCH\n   expected: %s\n   actual:   %s\n' "$1" "$3" "$2"
    mismatches=$((mismatches + 1))
  fi
}

echo "== (a) coding item with a repo code and a model label"
convert FAKE_ISSUE="$(issue "[SHOP-TOOLS] Foo" type:coding model:opus repo:shop-tools)" -- "$repo" 12
expect "exit" "$status" 0
expect "changed" "$(jq -c .changed <<<"$output")" true
expect "title" "$(jq -r .title <<<"$output")" "[SHOP-TOOLS] Sub-Epic: Foo"
expect "labels" "$(jq -c .labels <<<"$output")" '["repo:shop-tools","type:epic"]'
expect "calls" "$calls" "$read_call
ensure-labels.sh --repo $repo type:epic
issue edit 12 -R $repo --remove-label type:coding --remove-label model:opus --add-label type:epic --title [SHOP-TOOLS] Sub-Epic: Foo"

echo "== (b) already converted"
convert FAKE_ISSUE="$(issue "[SHOP-TOOLS] Sub-Epic: Foo" type:epic repo:shop-tools)" -- "$repo" 12
expect "exit" "$status" 0
expect "changed" "$(jq -c .changed <<<"$output")" false
expect "title" "$(jq -r .title <<<"$output")" "[SHOP-TOOLS] Sub-Epic: Foo"
expect "calls: only the read, no ensure-labels.sh, no issue edit" "$calls" "$read_call"

echo "== (c) epic without the prefix"
convert FAKE_ISSUE="$(issue "[SHOP-TOOLS] Foo" type:epic repo:shop-tools)" -- "$repo" 12
expect "exit" "$status" 0
expect "changed" "$(jq -c .changed <<<"$output")" true
expect "labels" "$(jq -c .labels <<<"$output")" '["repo:shop-tools","type:epic"]'
expect "calls: title only" "$calls" "$read_call
issue edit 12 -R $repo --title [SHOP-TOOLS] Sub-Epic: Foo"

echo "== (d) title without a repo code"
convert FAKE_ISSUE="$(issue "Foo" type:coding)" -- "$repo" 12
expect "exit" "$status" 0
expect "title" "$(jq -r .title <<<"$output")" "Sub-Epic: Foo"

echo "== (e) decision item"
convert FAKE_ISSUE="$(issue "Which store?" type:decision)" -- "$repo" 12
expect "exit" "$status" 3
expect "stderr names the type" "$(grep -c 'type:decision' "$work/stderr")" 1
expect "calls: no edit" "$calls" "$read_call"

echo "== (f) failing ensure-labels.sh"
convert FAKE_ENSURE_FAIL=1 FAKE_ISSUE="$(issue "Foo" type:coding)" -- "$repo" 12
expect "exit" "$status" 1
expect "no JSON" "$output" ""
expect "calls: no edit" "$(grep -c '^issue edit' <<<"$calls")" 0

echo "== (g) failing edit"
convert FAKE_EDIT_FAIL=1 FAKE_ISSUE="$(issue "Foo" type:coding)" -- "$repo" 12
expect "exit" "$status" 1
expect "no JSON" "$output" ""

echo "== (h) bad arguments"
convert FAKE_ISSUE='{}' -- "$repo"
expect "missing <n> exit" "$status" 2
expect "missing <n> calls" "$calls" ""
convert FAKE_ISSUE='{}' -- "$repo" twelve
expect "non-numeric <n> exit" "$status" 2
expect "non-numeric <n> calls" "$calls" ""
convert FAKE_ISSUE='{}' -- kp-skills 12
expect "repo without owner exit" "$status" 2
expect "repo without owner calls" "$calls" ""

echo
echo "mismatches: $mismatches"
exit $(( mismatches > 0 ? 1 : 0 ))
