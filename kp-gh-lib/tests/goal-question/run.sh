#!/usr/bin/env bash
# Drives goal-question.sh against the fakes in bin/ (gh, and create-item.sh found through
# KP_GH_LIB_BIN), which keep one issue's state in a file: an escalate → restore round trip
# on a body carrying a ``` fence and every marker kind, a re-run escalate on an escalated
# issue, and a create whose comment fails and is reverted. Offline — no GitHub — so this
# runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/goal-question.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PATH="$here/bin:$PATH" KP_GH_LIB_BIN="$here/bin" FAKE_STATE="$work" \
  KP_MSG_ME_SEND="$here/bin/send.sh"
failures=0
pr_url="https://github.com/example-org/demo-spec/pull/11"

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
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

field() { jq -cr "$1" "$work/issue.json"; }

# seed_issue <title> <body file> <label>
seed_issue() {
  jq -n --arg title "$1" --rawfile body "$2" --arg label "$3" \
    '{title: $title, body: $body, labels: [$label], comments: []}' > "$work/issue.json"
}

original="$work/original.md"
cat > "$original" <<'BODY'
<!-- human-only:start -->
Operator notes stay where they are.
<!-- human-only:end -->

**Which store keeps the sessions?** Postgres or Redis.

```sql
SELECT 1;
```

<details>
spec-ref: not-a-marker-inside-details
</details>

spec-ref: docs/spec.md#sessions
blocks: docs/spec.md#sessions
blocked-by: example-org/demo#3
resolves: example-org/demo#4
slice: sessions
parent: example-org/demo#5
milestone: M1
spec-pr: https://github.com/example-org/demo-spec/pull/9
goal-ref: docs/spec.md#latency
goal-answered: docs/spec.md#durability via https://github.com/example-org/demo-spec/pull/8
BODY
goal="$work/goal.md"
printf '**How fast must a session read be?**\n\nspec-ref: docs/spec.md#sessions\nblocks: docs/spec.md#sessions\n' > "$goal"
escalate_args=(escalate --repo example-org/demo --issue 7 --goal-title "How fast must a session read be?"
  --goal-body-file "$goal" --goal-ref docs/spec.md#goals --missing-fact "how fast a session read must be")

echo "== escalate then restore"
seed_issue "Which store keeps the sessions?" "$original" type:decision
output="$("$script" "${escalate_args[@]}")"
expect "escalate exits 0 as escalated" "$?:$(jq -r .action <<<"$output")" "0:escalated"
expect "escalate leaves the goal question" "$(field '[.title, .labels]')" \
  '["How fast must a session read be?",["type:question"]]'
expect "escalation fence outruns the body's" "$(field '.comments[0].body' | grep -c '^````$')" 2
expect "escalate pings the operator once" "$(cat "$work/sent.log")" \
  "example-org/demo#7 question: How fast must a session read be? — needs your call https://github.com/example-org/demo/issues/7"
output="$("$script" restore --repo example-org/demo --issue 7 --pr-url "$pr_url")"
expect "restore exits 0 as restored" "$?:$(jq -r .action <<<"$output")" "0:restored"
expected_body="$(cat "$original"; echo "goal-answered: docs/spec.md#goals via $pr_url")"
expect "restored body is the original plus one goal-answered line" "$(field .body)" "$expected_body"
expect "restored title and label" "$(field '[.title, .labels]')" \
  '["Which store keeps the sessions?",["type:decision"]]'
expect "one restored comment" "$(field '[.comments[].body | test("kp-resolve-spec-decision:restored")]')" \
  '[false,true]'
"$script" restore --repo example-org/demo --issue 7 --pr-url "$pr_url" > /dev/null
expect "re-run restore posts nothing and changes nothing" \
  "$(field '[(.comments | length), (.body | rtrimstr("\n"))]')" \
  "$(jq -c -n --arg body "$expected_body" '[2, $body]')"

echo "== escalate on an escalated issue"
seed_issue "Which store keeps the sessions?" "$original" type:decision
"$script" "${escalate_args[@]}" > /dev/null
output="$("$script" "${escalate_args[@]}")"
expect "second escalate is already-escalated" "$?:$(jq -c '[.action, .commentId]' <<<"$output")" \
  '0:["already-escalated",1000]'
expect "no second escalation comment" "$(field '.comments | length')" 1
expect "no ping for an already-escalated issue" "$(wc -l < "$work/sent.log" | tr -d ' ')" 2

echo "== create with a failing comment"
technical="$work/technical.md"
# The backticks are literal Markdown in the issue body, not a command substitution.
# shellcheck disable=SC2016
printf 'Which store? Run `/kp-resolve-spec-decision __ISSUE__`.\n\nspec-ref: docs/spec.md#sessions\n' > "$technical"
create_args=(create --repo example-org/demo --technical-body-file "$technical"
  --technical-title "Which store keeps the sessions?" --technical-type type:conflict
  --goal-body-file "$goal" --goal-title "How fast must a session read be?"
  --goal-ref docs/spec.md#goals --missing-fact "how fast a session read must be"
  --creator kp-do-gh-task --label priority:top)
output="$(FAKE_COMMENT_FAIL=1 "$script" "${create_args[@]}")"
expect "failed comment exits 3" "$?:$(jq -c '[.action, .skipped[0].step]' <<<"$output")" \
  '3:[null,"comment"]'
expect "technical title, body and label are back" "$(field '[.title, .body, .labels]')" \
  "$(sed 's/__ISSUE__/42/' "$technical" | jq -c -Rs \
    '["Which store keeps the sessions?", ., ["priority:top","type:conflict"]]')"

echo "== create then restore"
output="$("$script" "${create_args[@]}")"
expect "create exits 0 as created" "$?:$(jq -r .action <<<"$output")" "0:created"
expect "create records the technical type" \
  "$(field '.comments[0].body' | grep -c '^restore-type: type:conflict$')" 1
"$script" restore --repo example-org/demo --issue 42 --pr-url "$pr_url" > /dev/null
expect "restore puts the technical type back" "$(field '[.title, .labels]')" \
  '["Which store keeps the sessions?",["priority:top","type:conflict"]]'

if [ "$failures" -eq 0 ]; then
  echo "all goal-question checks passed"
else
  echo "$failures goal-question check(s) failed"
  exit 1
fi
