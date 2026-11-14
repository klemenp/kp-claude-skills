#!/usr/bin/env bash
# Runs body-parts.py split / assemble / strip on the bodies beside this script and
# compares the results with the hand-written *.expected.md files. `strip` is checked
# against the python3 one-liner kp-review-gh-pr hashed bodies with before the script
# existed, so every recorded body-sha256 stays valid. Offline (split --from-file), so this
# runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/body-parts.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

same() {
  local label=$1 expected=$2 actual=$3
  if cmp -s "$expected" "$actual"; then
    check "$label" ok
  else
    diff -u "$expected" "$actual"
    check "$label" MISMATCH
  fi
}

expect_status() {
  local label=$1 expected=$2 actual=$3
  if [ "$actual" -eq "$expected" ]; then
    check "$label" ok
  else
    cat "$work/stderr"
    check "$label (got $actual)" MISMATCH
  fi
}

run_status() {
  local status=0
  "$@" >/dev/null 2>"$work/stderr" || status=$?
  echo "$status"
}

# The hash kp-review-gh-pr computed before body-parts.py existed.
legacy_hash() {
  python3 -c 'import hashlib, re, sys; body = re.sub(r"<!--\s*human-only:start.*?(?:<!--\s*human-only:end\s*-->|\Z)", "", sys.stdin.read(), flags=re.DOTALL); print(hashlib.sha256(body.encode()).hexdigest())' < "$1"
}

strip_hash() {
  "$script" strip < "$1" | shasum -a 256 | cut -d' ' -f1
}

echo "== split: fenced body with markers"
status=$(run_status "$script" split example-org/demo 1 "$work/fenced" --from-file "$here/fenced.md")
expect_status "split fenced exits 0" 0 "$status"
same "fenced orig is the body" "$here/fenced.md" "$work/fenced-orig.md"
same "fenced fence" "$here/fenced.fence.expected.md" "$work/fenced-fence.md"
same "fenced markers" "$here/fenced.markers.expected.md" "$work/fenced-markers.md"

echo "== split: body with no fence"
status=$(run_status "$script" split example-org/demo 2 "$work/nofence" --from-file "$here/nofence.md")
expect_status "split nofence exits 0" 0 "$status"
if [ -f "$work/nofence-fence.md" ] && [ ! -s "$work/nofence-fence.md" ]; then
  check "nofence fence is empty" ok
else
  check "nofence fence is empty" MISMATCH
fi
same "nofence markers" "$here/nofence.markers.expected.md" "$work/nofence-markers.md"

echo "== split: unclosed fence"
status=$(run_status "$script" split example-org/demo 3 "$work/unclosed" --from-file "$here/unclosed.md")
if [ "$status" -eq 3 ] && grep -qx 'unclosed-fence' "$work/stderr" \
  && [ ! -e "$work/unclosed-fence.md" ] && [ ! -e "$work/unclosed-markers.md" ] \
  && cmp -s "$here/unclosed.md" "$work/unclosed-orig.md"; then
  check "unclosed-fence" ok
else
  check "unclosed-fence (exit $status)" MISMATCH
fi

echo "== assemble: round trip"
status=$(run_status "$script" assemble "$work/fenced" "$here/fenced.sections.md")
expect_status "assemble round trip exits 0" 0 "$status"
same "assemble draft" "$here/fenced.draft.expected.md" "$work/fenced-draft.md"

echo "== assemble: sections add a marker"
status=$(run_status "$script" assemble "$work/fenced" "$here/adds-marker.sections.md")
if [ "$status" -eq 1 ] && grep -q '^+blocked-by: #9$' "$work/stderr"; then
  check "sections-adds-a-marker" ok
else
  check "sections-adds-a-marker (exit $status)" MISMATCH
fi

echo "== strip: hash equals the legacy one-liner"
awk '{ printf "%s\r\n", $0 }' "$here/fenced.md" > "$work/crlf.md"
for body in "$here/fenced.md" "$here/unclosed.md" "$work/crlf.md"; do
  name="$(basename "$body" .md)"
  if [ "$(strip_hash "$body")" = "$(legacy_hash "$body")" ]; then
    check "strip hash $name" ok
  else
    check "strip hash $name" MISMATCH
  fi
done

echo "== bad arguments"
status=$(run_status "$script")
expect_status "no arguments exits 2" 2 "$status"

echo "mismatches: $failures"
[ "$failures" -eq 0 ]
