#!/usr/bin/env bash
# Drives repo-code.sh against the fake gh in bin/, which serves an issue list from the
# FAKE_ISSUES knob and logs every call: a config hit that calls nothing, a config miss
# resolved from the prefix already in use (a pull request ignored, a tie going to the code
# with the highest issue number), the derived code when nothing else answers, and bad
# arguments. Offline — no GitHub — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/repo-code.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PATH="$here/bin:$PATH" FAKE_LOG="$work/calls.log"
mismatches=0

config="$work/spec-sync.json"
printf '{"repoCodes": {"example-org/shop-tools": "SKILL", "my-org/shop-data-api": "BE"}}\n' > "$config"
printf '{"repoCodes": ' > "$work/broken.json"
missing="$work/absent.json"

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || mismatches=$((mismatches + 1))
}

# expect <label> <actual> <expected>
expect() {
  if [ "$2" = "$3" ]; then
    check "$1" ok
  else
    printf 'expected: %s\nactual:   %s\n' "$3" "$2"
    check "$1" MISMATCH
  fi
}

# once <issues JSON array> <args…> — runs the script against that issue list, leaving
# "<exit>:<stdout>" in $outcome and the calls in $FAKE_LOG
once() {
  local output status=0
  : > "$FAKE_LOG"
  output="$(FAKE_ISSUES="$1" "$script" "${@:2}" 2>/dev/null)" || status=$?
  outcome="$status:$output"
}

logged() { wc -l < "$FAKE_LOG" | tr -d ' '; }

echo "== config hit → no gh call"
once '[]' example-org/shop-tools --config "$config"
expect "prints the configured code" "$outcome" '0:{"code": "SKILL", "label": "repo:shop-tools"}'
expect "no call logged" "$(logged)" 0

echo "== config miss → the prefix already in use, the pull request ignored"
issues='[
  {"number": 3, "title": "[APP] First"},
  {"number": 5, "title": "[APP] Second"},
  {"number": 9, "title": "[WEB] A PR", "pull_request": {}},
  {"number": 10, "title": "[WEB] Another PR", "pull_request": {}},
  {"number": 11, "title": "[WEB] Third PR", "pull_request": {}},
  {"number": 12, "title": "No prefix"}
]'
once "$issues" example-org/demo-app --config "$config"
expect "prints the issue prefix" "$outcome" '0:{"code": "APP", "label": "repo:demo-app"}'
expect "one REST issue read, labelled" "$(cat "$FAKE_LOG")" \
  'api repos/example-org/demo-app/issues\?state=all\&labels=repo:demo-app\&per_page=100 '

echo "== tie → the code whose own highest issue number is largest"
issues='[
  {"number": 20, "title": "[OLD] Newest"},
  {"number": 4,  "title": "[OLD] Oldest"},
  {"number": 15, "title": "[NEW] Middle"},
  {"number": 19, "title": "[NEW] Later"}
]'
once "$issues" example-org/demo-app --config "$config"
expect "OLD (20) beats NEW (19)" "$outcome" '0:{"code": "OLD", "label": "repo:demo-app"}'

echo "== more frequent beats a higher number"
issues='[
  {"number": 30, "title": "[ONE] Latest"},
  {"number": 1,  "title": "[TWO] a"},
  {"number": 2,  "title": "[TWO] b"}
]'
once "$issues" example-org/demo-app --config "$config"
expect "TWO (2 issues) beats ONE (1)" "$outcome" '0:{"code": "TWO", "label": "repo:demo-app"}'

echo "== no config file, no prefixed issue → derived"
once '[]' my-org/shop-data-api --config "$missing"
expect "three segments drop the first" "$outcome" '0:{"code": "DATA-API", "label": "repo:shop-data-api"}'
once '[{"number": 1, "title": "[lower] not a code"}]' example-org/shop-tools --config "$missing"
expect "two segments keep both" "$outcome" '0:{"code": "SHOP-TOOLS", "label": "repo:shop-tools"}'

echo "== the default config is .claude/spec-sync.json under the current directory"
mkdir -p "$work/checkout/.claude"
cp "$config" "$work/checkout/.claude/spec-sync.json"
: > "$FAKE_LOG"
outcome="$(cd "$work/checkout" && "$script" example-org/shop-tools 2>/dev/null)"
expect "reads the default config" "$outcome" '{"code": "SKILL", "label": "repo:shop-tools"}'

echo "== bad arguments → exit 2, no call"
once '[]'
expect "no repo" "$outcome" "2:"
once '[]' shop-tools --config "$config"
expect "not owner/name" "$outcome" "2:"
once '[]' example-org/demo --config
expect "--config without a value" "$outcome" "2:"
once '[]' example-org/demo --config "$work/broken.json"
expect "unparseable config" "$outcome" "2:"
expect "no call logged" "$(logged)" 0

echo "== failed issue read → exit 1"
FAKE_READ_FAIL=1 once '[]' example-org/demo-app --config "$missing"
expect "exits 1, prints nothing" "$outcome" "1:"

echo
echo "mismatches: $mismatches"
exit $(( mismatches > 0 ? 1 : 0 ))
