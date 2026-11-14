#!/usr/bin/env bash
# Feeds every <name>.json fixture ({"args": [...], "body": "..."}) through set-marker.sh
# --from-file, and diffs the result against the hand-written <name>.expected.json. Then
# checks that bad arguments exit 2, and, with a stub `gh` on PATH, that a changing call
# writes the body exactly once and a no-op call never writes. Offline, so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/set-marker.sh"
failures=0

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

for fixture in "$here"/*.json; do
  case "$fixture" in *.expected.json) continue ;; esac
  name="$(basename "$fixture" .json)"
  echo "== $name"
  args=()
  while IFS= read -r arg; do args+=("$arg"); done < <(jq -r '.args[]' "$fixture")
  if ! actual="$("$script" "${args[@]}" --from-file "$fixture" 2>&1)"; then
    printf '%s\n' "$actual"
    check "$name" MISMATCH
    continue
  fi
  if diff -u <(jq -S . "$here/$name.expected.json") <(jq -S . <<<"$actual"); then
    check "$name" ok
  else
    check "$name" MISMATCH
  fi
done

# Bad arguments are exit 2, distinct from a GitHub failure.
expect_usage_error() {
  local label=$1 status=0
  shift
  "$script" "$@" >/dev/null 2>&1 || status=$?
  if [ "$status" -eq 2 ]; then check "$label exits 2" ok; else check "$label exits 2" MISMATCH; fi
}
expect_usage_error "no action" example-org/demo 7 blocked-by
expect_usage_error "two actions" example-org/demo 7 blocked-by --add '#1' --remove '#2'
expect_usage_error "non-numeric issue" example-org/demo x7 blocked-by --add '#1'
expect_usage_error "bad repo" demo 7 blocked-by --add '#1'
expect_usage_error "empty value" example-org/demo 7 blocked-by --remove ''

# Stub gh: `issue view` answers from $STUB_BODY (as --jq prints it, with a trailing
# newline); every `issue edit` appends its argument vector to $STUB_LOG.
stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT
cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "issue view") cat "$STUB_BODY"; echo ;;
  "issue edit") echo "$*" >>"$STUB_LOG" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$stub_dir/gh"
export STUB_BODY="$stub_dir/body.md" STUB_LOG="$stub_dir/edits.log"
printf 'spec-ref: x\nblocked-by: #4\n' >"$STUB_BODY"

stubbed_edits() {
  : >"$STUB_LOG"
  PATH="$stub_dir:$PATH" "$script" example-org/demo 7 blocked-by "$@" >/dev/null 2>&1 || echo failed
  cat "$STUB_LOG"
}

edits="$(stubbed_edits --add '#5')"
if [ "$(grep -c . <<<"$edits")" -eq 1 ] && [[ "$edits" == "issue edit 7 -R example-org/demo --body-file "* ]]; then
  check "a change writes once" ok
else
  printf '%s\n' "$edits"
  check "a change writes once" MISMATCH
fi

edits="$(stubbed_edits --add 'example-org/demo#4')"
if [ -z "$edits" ]; then
  check "a no-op never writes" ok
else
  printf '%s\n' "$edits"
  check "a no-op never writes" MISMATCH
fi

echo "mismatches: $failures"
[ "$failures" -eq 0 ]
