# shellcheck shell=bash
# Shared by the fakes: the launch count so far, and the case fixture in force at it —
# <name>.<k>.<ext> with the highest k not above the count, the case's own copy before the
# suite's default.
launches() { cat "$FAKE_STATE/launches" 2>/dev/null || echo 0; }

fixture_at() {
  local name=$1 ext=$2 k
  for ((k = $(launches); k >= 0; k--)); do
    if [ -f "$FAKE_DIR/$name.$k.$ext" ]; then
      cat "$FAKE_DIR/$name.$k.$ext"
      return
    fi
  done
  echo "fake: no $name.<k>.$ext at launch $(launches) in $FAKE_DIR" >&2
  exit 1
}

fixture() {
  if [ -f "$FAKE_DIR/$1" ]; then cat "$FAKE_DIR/$1"; else cat "$FAKE_DIR/../../$1"; fi
}

record() { printf '%s\n' "$*" >> "$FAKE_STATE/calls"; }

# The 1-based number of this call to <name>, counted in $FAKE_STATE/<name>-calls.
call_number() {
  local counter="$FAKE_STATE/$1-calls" n
  n=$(($(cat "$counter" 2>/dev/null || echo 0) + 1))
  echo "$n" > "$counter"
  echo "$n"
}

# The case's <name>.call<j>.json with the highest j not above call <n>; fails when none.
fixture_by_call() {
  local name=$1 n=$2 j
  for ((j = n; j >= 1; j--)); do
    if [ -f "$FAKE_DIR/$name.call$j.json" ]; then
      cat "$FAKE_DIR/$name.call$j.json"
      return 0
    fi
  done
  return 1
}
