#!/usr/bin/env bash
# Runs lint-item.py over every fixture and checks the result its name promises:
# pass-*.md exits 0; fail-<rule>-*.md exits 1 with only `FAIL <rule>:` lines.
# Then reruns the via-parent fixture with a failing `gh` first on PATH and expects exit 4
# (its parent-issue lookup is never cached, so the stub is always reached).
# The spec-backed fixtures name the invented spec in spec/, which the `gh` stub in bin/
# serves as example-org/shop-spec, with the issues in case/. The scripts run from a temp
# copy of kp-gh-lib/scripts/, so their spec caches land in the temp directory, never in
# this repo's kp-gh-lib/state/. Offline — no real `gh`, no GitHub — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/kp-gh-lib" "$work/failing-gh"
cp -R "$repo_root/kp-gh-lib/scripts" "$work/kp-gh-lib/scripts"
lint="$work/kp-gh-lib/scripts/lint-item.py"
export PATH="$here/bin:$PATH"
rules="context-resolve rules-source serves-present serves-match via-parent spec-gap ac-proof sections sweep"
failures=0

rule_of() {
  local name="${1#fail-}" rule
  for rule in $rules; do
    case "$name" in "$rule"-*) echo "$rule"; return ;; esac
  done
}

lint_fixture() {
  python3 "$lint" --repo example-org/shop-api --body-file "$1" --code-root "$repo_root" 2>&1
}

for fixture in "$here"/*.md; do
  name="$(basename "$fixture" .md)"
  output="$(lint_fixture "$fixture")"
  status=$?
  printf '== %s (exit %s)\n%s\n' "$name" "$status" "$output"
  fail_lines="$(grep '^FAIL ' <<<"$output")"
  result=MISMATCH
  case "$name" in
    pass-*)
      if [ "$status" -eq 0 ] && [ -z "$fail_lines" ]; then result=ok; fi ;;
    fail-*)
      rule="$(rule_of "$name")"
      if [ -n "$rule" ] && [ "$status" -eq 1 ] && [ -n "$fail_lines" ] \
          && ! grep -qv "^FAIL $rule: " <<<"$fail_lines"; then
        result=ok
      fi ;;
  esac
  echo "-> $result"
  [ "$result" = ok ] || failures=$((failures + 1))
done

printf '#!/bin/sh\necho "error connecting to api.github.com" >&2\nexit 1\n' > "$work/failing-gh/gh"
chmod +x "$work/failing-gh/gh"
output="$(PATH="$work/failing-gh:$PATH" lint_fixture "$here/pass-via-parent.md")"
status=$?
printf '== gh shadowed to fail (exit %s)\n%s\n' "$status" "$output"
if [ "$status" -eq 4 ]; then echo "-> ok"; else echo "-> MISMATCH (want exit 4)"; failures=$((failures + 1)); fi

echo "mismatches: $failures"
[ "$failures" -eq 0 ]
