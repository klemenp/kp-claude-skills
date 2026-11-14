#!/usr/bin/env bash
# Runs refresh-pins.py over crafted bodies against a throwaway spec repo whose two commits
# are spec-before.md and spec-after.md, and checks each plan: an identical section is only
# a SHA bump, a changed one carries its diff, a removed anchor is left alone, removed and
# non-goal goals are drift, and every non-pin byte (CRLF bodies included) is unchanged.
# Offline: git only, no gh.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
refresh="$here/../../scripts/refresh-pins.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

spec="$work/spec"
git init -q "$spec"
commit_spec() {
  cp "$1" "$spec/TECH_SPEC.md"
  git -C "$spec" add TECH_SPEC.md
  git -C "$spec" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm "$2"
  git -C "$spec" rev-parse HEAD
}
old_sha="$(commit_spec "$here/spec-before.md" before)"
new_sha="$(commit_spec "$here/spec-after.md" after)"

failures=0

# check <fixture> <expected pin statuses, space-separated> <expected drift, goal:reason ...>
check() {
  local name=$1 statuses=$2 drift=$3 body="$work/$1" out="$work/$1.out" report status
  report="$("$refresh" --spec-dir "$spec" --spec-repo fixture/spec --sha "$new_sha" \
    --body-file "$body" --out "$out")"
  status=$?
  printf '== %s (exit %s)\n%s\n' "$name" "$status" "$report"
  printf '%s' "$report" > "$work/$name.json"
  if python3 - "$body" "$out" "$old_sha" "$new_sha" "$statuses" "$drift" "$status" "$work/$name.json" <<'EOF'
import json, sys
body_file, out_file, old_sha, new_sha, statuses, drift, status, report_file = sys.argv[1:]
report = json.load(open(report_file))
problems = []
if status != "0":
    problems.append(f"exit {status}")
got = " ".join(pin["status"] for pin in report["pins"])
if got != statuses:
    problems.append(f"statuses {got!r}, expected {statuses!r}")
got_drift = " ".join(f"{d['goal']}:{d['reason']}" for d in report["goalDrift"])
if got_drift != drift:
    problems.append(f"drift {got_drift!r}, expected {drift!r}")
before = open(body_file, "rb").read().split(b"\n")
after = open(out_file, "rb").read().split(b"\n")
bumped = {pin["line"] for pin in report["pins"] if pin["status"] in ("unchanged", "changed")}
if len(before) != len(after):
    problems.append("line count changed")
for number, (old, new) in enumerate(zip(before, after), start=1):
    expected = old.replace(old_sha.encode(), new_sha.encode()) if number in bumped else old
    if new != expected:
        problems.append(f"line {number}: {old!r} became {new!r}")
for pin in report["pins"]:
    if pin["status"] == "changed" and not pin.get("diff"):
        problems.append(f"line {pin['line']}: changed without a diff")
for problem in problems:
    print(f"  MISMATCH {problem}")
sys.exit(1 if problems else 0)
EOF
  then
    echo "  ok"
  else
    failures=$((failures + 1))
  fi
}

for fixture in body-unchanged body-changed body-goal-drift; do
  sed "s/__OLD__/$old_sha/g" "$here/$fixture.md" > "$work/$fixture.md"
done
sed 's/$/\r/' "$work/body-unchanged.md" > "$work/body-unchanged-crlf.md"

check body-unchanged.md "unchanged unchanged" ""
check body-unchanged-crlf.md "unchanged unchanged" ""
check body-changed.md "changed missing" "G-2:changed"
check body-goal-drift.md "unchanged" "G-3:non-goal G-4:removed"

# A refreshed body is already current: a second pass plans nothing.
cp "$work/body-unchanged.md.out" "$work/body-refreshed.md"
check body-refreshed.md "current current" ""
if ! grep -q '"bodyChanged": false' <<<"$("$refresh" --spec-dir "$spec" --spec-repo fixture/spec \
    --sha "$new_sha" --body-file "$work/body-refreshed.md" --out "$work/again.out")"; then
  echo "  MISMATCH second pass changed the body"
  failures=$((failures + 1))
fi

# A pin whose commit the clone lacks is a read failure, never a content verdict.
sed "s/$old_sha/0000000000000000000000000000000000000000/" "$work/body-changed.md" > "$work/body-unknown.md"
"$refresh" --spec-dir "$spec" --spec-repo fixture/spec --sha "$new_sha" \
  --body-file "$work/body-unknown.md" --out "$work/unknown.out" 2>/dev/null
status=$?
echo "== body-unknown.md (exit $status)"
if [ "$status" -ne 4 ]; then
  echo "  MISMATCH expected exit 4"
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
