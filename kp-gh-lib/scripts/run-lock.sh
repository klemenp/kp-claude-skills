#!/usr/bin/env bash
# Take, release or report an exclusive per-key run lock, so two runs never drive the same
# work item at once. `kp-do-gh-task-loop` §0.4 holds one per item for its whole run and
# releases it in §4; `kp-do-gh-ready-items` §3 reads it before launching or judging a
# task-loop child.
#
# Usage: run-lock.sh (acquire|release|status) --workspace <dir> <key> [--pid <n>]
#
#   The lock is <dir>/.kp-locks/<key>.lock; <key> matches ^[A-Za-z0-9._-]+$ and <dir> must
#   already exist (acquire creates .kp-locks/). The owner pid is --pid, else $CLAUDE_PID
#   (the Claude CLI process, set in every Bash tool call), else $PPID — so a skill's lock
#   lives exactly as long as its session. The file holds four lines: pid=, started= (UTC
#   ISO-8601), session=$CLAUDE_CODE_SESSION_ID and log=$KP_CHILD_LOG. It is written to a
#   tmp file and hard-linked into place, so it appears atomically and complete.
#
#   A recorded pid is alive when `kill -0` succeeds or fails with "Operation not
#   permitted". A lock whose pid is dead, or that has no numeric pid= line, is stale.
#
#   acquire  free → `acquired key=<k> pid=<owner>`; held by the owner →
#            `acquired key=<k> pid=<owner> reentrant` (file untouched); held by a live pid
#            → `held key=<k> pid=… started=… session=… log=…`, exit 3; stale → taken over:
#            `acquired key=<k> pid=<owner> takeover=<dead pid> stale-since=<started>`,
#            plus a `took over stale lock` line on stderr.
#   release  missing → `not-held key=<k>`; owned → removed, `released key=<k>`; otherwise
#            `not-owner key=<k> pid=<holder>`, exit 3, file untouched.
#   status   read-only: `free key=<k>`, `held key=<k> pid=… started=… session=… log=…` or
#            `stale key=<k> pid=… started=… session=… log=…`.
#
# Exit: 0 as above · 1 I/O failure (cannot create the directory, write the tmp file, read
# or remove the lock) · 2 bad arguments · 3 held by another live pid (acquire) or not the
# owner (release).
set -euo pipefail

EXIT_IO=1
EXIT_HELD=3
# Each round of acquire either settles or loses a race to another taker; a few rounds
# bound the loop when the lock keeps vanishing under it.
MAX_ACQUIRE_ROUNDS=5

usage() {
  echo "usage: run-lock.sh (acquire|release|status) --workspace <dir> <key> [--pid <n>]" >&2
  exit 2
}

fail() {
  printf 'run-lock.sh: %s\n' "$1" >&2
  exit "$EXIT_IO"
}

verb="" workspace="" key="" pid_flag=""
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) [ $# -ge 2 ] || usage; workspace=$2; shift 2 ;;
    --pid) [ $# -ge 2 ] || usage; pid_flag=$2; shift 2 ;;
    -*) usage ;;
    *)
      if [ -z "$verb" ]; then verb=$1
      elif [ -z "$key" ]; then key=$1
      else usage
      fi
      shift ;;
  esac
done

case "$verb" in acquire|release|status) ;; *) usage ;; esac
[ -n "$workspace" ] && [ -n "$key" ] || usage
[[ "$key" =~ ^[A-Za-z0-9._-]+$ ]] || usage
[ -d "$workspace" ] || usage
if [ -n "$pid_flag" ]; then
  [[ "$pid_flag" =~ ^[0-9]+$ ]] || usage
  owner=$pid_flag
else
  owner=${CLAUDE_PID:-$PPID}
  [[ "$owner" =~ ^[0-9]+$ ]] || usage
fi

lock_dir="$workspace/.kp-locks"
lock="$lock_dir/$key.lock"

# read_lock <file>: sets content/holder/started/session/log; returns 1 when the file is
# missing, and exits 1 when it exists but cannot be read.
read_lock() {
  if ! content=$(cat "$1" 2>/dev/null); then
    [ -e "$1" ] && fail "cannot read $1"
    return 1
  fi
  parse_lock "$content"
}

parse_lock() {
  holder=$(sed -nE 's/^pid=([1-9][0-9]*)$/\1/p' <<<"$1" | head -n 1)
  started=$(sed -n 's/^started=//p' <<<"$1" | head -n 1)
  session=$(sed -n 's/^session=//p' <<<"$1" | head -n 1)
  log=$(sed -n 's/^log=//p' <<<"$1" | head -n 1)
}

alive() {
  [ -n "$1" ] || return 1
  local err
  err=$(LC_ALL=C kill -0 "$1" 2>&1) && return 0
  [[ "$err" == *"Operation not permitted"* ]]
}

describe() { # state
  echo "$1 key=$key pid=$holder started=$started session=$session log=$log"
}

# create_lock: writes the tmp file and links it into place; returns 1 when a lock is
# already there.
create_lock() {
  local tmp="$lock.tmp.$$" linked=0
  # The braces make 2>/dev/null cover the redirection's own error, not just printf's.
  { printf 'pid=%s\nstarted=%s\nsession=%s\nlog=%s\n' "$owner" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${CLAUDE_CODE_SESSION_ID:-}" "${KP_CHILD_LOG:-}" \
    > "$tmp"; } 2>/dev/null || { rm -f "$tmp"; fail "cannot write $tmp"; }
  ln "$tmp" "$lock" 2>/dev/null || linked=1
  rm -f "$tmp"
  if [ "$linked" -ne 0 ] && [ ! -e "$lock" ]; then fail "cannot create $lock"; fi
  return "$linked"
}

# print_current_held: reports whoever holds the lock now and exits 3.
print_current_held() {
  read_lock "$lock" || { holder="" started="" session="" log=""; }
  describe held
  exit "$EXIT_HELD"
}

acquire() {
  mkdir -p "$lock_dir" 2>/dev/null || fail "cannot create $lock_dir"
  local round stale_copy before
  for ((round = 1; round <= MAX_ACQUIRE_ROUNDS; round++)); do
    if create_lock; then
      echo "acquired key=$key pid=$owner"
      return 0
    fi
    read_lock "$lock" || continue
    if [ "$holder" = "$owner" ]; then
      echo "acquired key=$key pid=$owner reentrant"
      return 0
    fi
    if alive "$holder"; then
      describe held
      exit "$EXIT_HELD"
    fi

    # Stale: move it aside, and take over only if what moved is what was judged dead.
    before=$content
    local dead=$holder stale_since=$started
    stale_copy="$lock.stale.$$"
    mv "$lock" "$stale_copy" 2>/dev/null || continue
    read_lock "$stale_copy" || fail "cannot read $stale_copy"
    if [ "$content" != "$before" ]; then
      # Another taker replaced the lock between the read and the move: put it back.
      if ln "$stale_copy" "$lock" 2>/dev/null; then
        rm -f "$stale_copy"
        describe held
        exit "$EXIT_HELD"
      fi
      rm -f "$stale_copy"
      print_current_held
    fi
    if ! create_lock; then
      rm -f "$stale_copy"
      print_current_held
    fi
    rm -f "$stale_copy"
    echo "acquired key=$key pid=$owner takeover=$dead stale-since=$stale_since"
    echo "run-lock.sh: took over stale lock $key from dead pid $dead" >&2
    return 0
  done
  fail "could not settle $lock after $MAX_ACQUIRE_ROUNDS rounds"
}

release() {
  if ! read_lock "$lock"; then
    echo "not-held key=$key"
    return 0
  fi
  if [ "$holder" != "$owner" ]; then
    echo "not-owner key=$key pid=$holder"
    exit "$EXIT_HELD"
  fi
  rm -f "$lock" 2>/dev/null || fail "cannot remove $lock"
  echo "released key=$key"
}

status() {
  if ! read_lock "$lock"; then
    echo "free key=$key"
    return 0
  fi
  if alive "$holder"; then describe held; else describe stale; fi
}

"$verb"
