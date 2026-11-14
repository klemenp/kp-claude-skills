#!/usr/bin/env bash
# Run one verification command (a test, lint or build) with its output kept out of the
# caller's context: everything it prints goes to a log, and the caller sees one result
# line, plus the log's last lines when the command failed or timed out.
# `kp-do-gh-task` §4.3 and `kp-fix-pr` §3.3 run every verification command through it.
#
# Usage: run-verify.sh --log <path> [--tail <n>] [--timeout-sec <s>] -- <command> [args…]
#
#   Runs <command> in the current directory, stdin from /dev/null, with its stdout and
#   stderr merged in arrival order into <path> — truncated first, its parent directory
#   created. The script's own lines go to its stdout and never into the log.
#
#   --timeout-sec  integer 1–540, default 540 (one foreground Bash call under the
#                  10-minute cap). On expiry the command's process group gets TERM, then
#                  KILL 5 seconds later.
#   --tail         integer ≥ 1, default 80.
#   A repeated option takes its last value.
#
#   Output, first line always:
#     result=<pass|fail|timeout> exit=<code> seconds=<elapsed> lines=<n> log=<path>
#   exit is the command's exit code; 124 on timeout; 128+<signal> when a signal ended it
#   (result=fail); 127 when it is not found and 126 when it cannot be executed (both
#   result=fail, empty log). seconds is whole, rounded down; lines counts
#   str.splitlines() of the log. On fail or timeout it then prints
#   `--- last <k> of <lines> lines ---` and the log's last k = min(tail, lines) lines,
#   byte for byte.
#
# Exit: 0 the command ran (or could not be started), whatever its result — the result
# line carries it · 1 the log cannot be created · 2 bad arguments, nothing run.
set -euo pipefail

python3 "$(dirname "${BASH_SOURCE[0]}")"/py/run_verify.py "$@" </dev/null
