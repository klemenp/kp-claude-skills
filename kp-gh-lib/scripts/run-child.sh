#!/usr/bin/env bash
# Launch a headless `claude -p` child with the family's standard flag set, then wait for
# it in the foreground — the launch-detached / poll-a-sentinel dance the loop skills used
# to restate in prose (`NOTES.md` § *Waiting in a headless session*).
#
# Usage:
#   run-child.sh --log <path> --cwd <dir> [--model <m>] [--effort <level>] [--timeout-min <n>]
#                [--chrome] -- <prompt>
#   run-child.sh --wait <log> [--wait-max-sec <s>]
#   run-child.sh --list
#
# `--chrome` passes `--chrome` to the child, for a child that drives Claude in Chrome.
#
# `--model` takes a model alias, a full model name or a tier (`model-label.sh`): a tier's
# effort suffix is stripped, `opus-high` launches `--model opus --effort high`. `--effort
# <level>` (low|medium|high|xhigh|max) sets the reasoning effort and wins over a suffix.
# The CLI only warns on an unknown effort and runs at the default, so the level is
# validated here. When an effort results, the child gets `--effort <level>` and
# KP_EFFORT=<level> in its environment; with none, neither is added.
#
# Every child runs with KP_HEADLESS_CHILD=1 in its environment, so a session can tell it
# is not top-level: `kp-msg-me/scripts/send.sh --session-end` drops a child's wrap-up.
# It also carries KP_CHILD_LOG=<log>, so a lock the child takes can name its log.
#
# A detached child outlives the session that launched it, so each one is registered while
# it runs: ${KP_CHILDREN_DIR:-$HOME/.claude/kp-children}/<run id> holds key=value lines
# (pid of the detached wrapper, child pid, started, started_epoch, cwd, log, prompt). The
# entry is removed just before the sentinel is written, or when the wrapper exits early.
# `--list` prints one line per live entry,
#   pid=<pid> elapsed=<[Nd]HH:MM:SS> cwd=<dir> log=<path> prompt=<first 80 chars>[…]
# or `no live children`, and prunes an entry whose wrapper is gone (a SIGKILLed one).
#
# Every child also carries a unique KP_RUN_ID, which everything it starts inherits —
# including `nohup … &` jobs, which Claude Code puts in a new process group and which are
# reparented to PID 1, out of reach of a process-group or process-tree kill. On timeout,
# and again once the child exits, every process carrying that id is sent TERM, then KILL
# after a grace period, so a killed child's detached build can't keep running into the
# next attempt. Gradle daemons and their workers are spared: a daemon outlives the build
# that started it and may be serving another session's build; killing this child's
# `gradlew` client is what cancels its build.
#
# The launch call returns as soon as the child is detached; each wait call returns within
# <s> seconds (default 480, under the caller's 10-min foreground cap) with
# `status: running` so the caller simply calls it again. Every path is derived from
# <log> — the child's output, its `<log>.exit` sentinel — so no shell variable has to
# survive between the caller's `Bash` calls. A fresh <log> per launch: the launcher
# clears a previous run's sentinel, but two live children sharing one log overwrite each
# other.
#
# Once the child has finished, prints one line:
#   exit=<code> capacity=<none|session-limit|weekly-limit> [reset='<text>'] log=<path>
# `capacity` is the Claude usage limit the child's log reports — a quota-killed child
# exits 0 without touching GitHub, so the caller must tell that from real work. `reset`
# is the reset time when the limit line names one.
#
# Exit: 0 the child finished (whatever its own exit code) · 3 still running · 1 launch
# failure (for `--list`: an unreadable registry) · 2 bad arguments.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$here/headless-settings.json"
MODEL_LABEL="$here/model-label.sh"
EFFORT_RE='^(low|medium|high|xhigh|max)$'
AUTOCOMPACT=150k
POLL_SECONDS=5
DEFAULT_WAIT_MAX_SECONDS=480
DEFAULT_TIMEOUT_MINUTES=120
SWEEP_GRACE_SECONDS=10
GRADLE_SHARED_RE='GradleDaemon|GradleWorkerMain'
REGISTRY_DIR="${KP_CHILDREN_DIR:-$HOME/.claude/kp-children}"
LIST_PROMPT_CHARS=80
SECONDS_PER_DAY=86400
# The detached wrapper's registry entry. A global, not a local, so the EXIT trap still
# resolves it after run_detached returns.
registry_entry=

usage() {
  cat >&2 <<'EOF'
usage: run-child.sh --log <path> --cwd <dir> [--model <m>] [--effort <level>] [--timeout-min <n>]
                    [--chrome] -- <prompt>
       run-child.sh --wait <log> [--wait-max-sec <s>]
       run-child.sh --list
Registry: ${KP_CHILDREN_DIR:-$HOME/.claude/kp-children}. Every child gets
KP_HEADLESS_CHILD=1, KP_RUN_ID and KP_CHILD_LOG=<log> in its environment.
--model takes an alias, a full name or a tier with an effort suffix (opus-high);
--effort is one of low|medium|high|xhigh|max and wins over a suffix. An effort
reaches the child as --effort <level> and KP_EFFORT=<level>.
EOF
  exit 2
}

fail() {
  printf 'run-child.sh: %s\n' "$1" >&2
  exit 1
}

# The log line the Claude CLI prints when a run is refused for capacity. Prose that
# merely mentions a limit is not a hit, so a negation (no, not, never, neither, nor)
# before the phrase ("no child hit the usage limit" — a parent's own report, quoted into
# its log) never counts.
LIMIT_RE='(session|usage|weekly|[0-9]+-hour)[[:space:]]+limit|hit your ([[:alnum:]-]+ )?limit'
NEGATED_RE='(^|[^[:alnum:]])(no|not|never|neither|nor)([^[:alnum:]].*)?('$LIMIT_RE')'

capacity_line() {
  grep -iE "$LIMIT_RE" "$1" 2>/dev/null | grep -viE "$NEGATED_RE" | head -1 || true
}

report_finished() {
  local log=$1 code=$2 limit capacity=none reset=
  limit=$(capacity_line "$log")
  if [ -n "$limit" ]; then
    capacity=session-limit
    printf '%s' "$limit" | grep -qi weekly && capacity=weekly-limit
    reset=$(printf '%s' "$limit" | grep -ioE 'resets? [^|]*' | head -1 || true)
  fi
  if [ -n "$reset" ]; then
    printf "exit=%s capacity=%s reset='%s' log=%s\n" "$code" "$capacity" "$reset" "$log"
  else
    printf 'exit=%s capacity=%s log=%s\n' "$code" "$capacity" "$log"
  fi
}

wait_for_child() {
  local log=$1 wait_max=$2 deadline remaining
  deadline=$(( $(date +%s) + wait_max ))
  while [ ! -f "$log.exit" ]; do
    remaining=$(( deadline - $(date +%s) ))
    if [ "$remaining" -le 0 ]; then
      printf 'status: running log=%s\n' "$log"
      exit 3
    fi
    # Never sleep past the budget: the caller sized its own foreground timeout on it.
    [ "$remaining" -gt "$POLL_SECONDS" ] && remaining=$POLL_SECONDS
    sleep "$remaining"
  done
  report_finished "$log" "$(cat "$log.exit")"
  exit 0
}

# Pids of the live processes carrying KP_RUN_ID=<id>, minus Gradle daemons and workers.
tagged_pids() {
  local tag="KP_RUN_ID=$1" environ pid cmdline
  if [ -d /proc/self ]; then
    for environ in /proc/[0-9]*/environ; do
      pid=${environ#/proc/}
      pid=${pid%/environ}
      grep -qxzF "$tag" "$environ" 2>/dev/null || continue
      cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || continue
      [[ $cmdline =~ $GRADLE_SHARED_RE ]] && continue
      echo "$pid"
    done
  else
    # macOS: `ps -E` appends each process's environment to its command line.
    # shellcheck disable=SC2009 # pgrep -f does not see the environment that ps -E appends
    ps -Eww -ax -o pid=,command= | grep -E " $tag( |\$)" | grep -vE "$GRADLE_SHARED_RE" \
      | awk '{ print $1 }' || true
  fi
}

# TERM every process of the run, then KILL whatever outlives the grace period.
sweep_run() {
  local run_id=$1 pids waited=0
  pids=$(tagged_pids "$run_id")
  [ -n "$pids" ] || return 0
  # shellcheck disable=SC2086 # one pid per word
  kill -TERM $pids 2>/dev/null || true
  while [ "$waited" -lt "$SWEEP_GRACE_SECONDS" ]; do
    pids=$(tagged_pids "$run_id")
    [ -n "$pids" ] || return 0
    sleep 1
    waited=$(( waited + 1 ))
  done
  # shellcheck disable=SC2086 # one pid per word
  kill -KILL $pids 2>/dev/null || true
}

# Writes the registry entry through a dot-file tmp + mv, so `--list` never reads a
# partial one. A failure is noted in the child's log and never stops the child.
register_child() {
  local child_pid=$1 cwd=$2 log=$3 prompt=$4 tmp error
  tmp="$REGISTRY_DIR/.${registry_entry##*/}.tmp"
  prompt=${prompt//$'\n'/ }
  prompt=${prompt//$'\t'/ }
  if ! error=$( {
      mkdir -p "$REGISTRY_DIR" &&
        printf 'pid=%s\nchild=%s\nstarted=%s\nstarted_epoch=%s\ncwd=%s\nlog=%s\nprompt=%s\n' \
          "$$" "$child_pid" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date +%s)" "$cwd" "$log" \
          "$prompt" > "$tmp" &&
        mv "$tmp" "$registry_entry"
    } 2>&1 ); then
    rm -f "$tmp" 2>/dev/null || true
    printf 'run-child.sh: cannot register child: %s\n' "${error:-write failed}" >> "$log" || true
  fi
}

# Hidden mode: the detached body. It owns the child, enforces the timeout, and records
# the exit code in the sentinel — written last, so the sentinel's existence means done.
run_detached() {
  local log=$1 timeout_seconds=$2 cwd=$3 model=$4 prompt=$5 chrome=$6 effort=$7
  local run_id child killer code=0 child_command
  run_id="run-child-$$-$(date +%s)"
  registry_entry="$REGISTRY_DIR/$run_id"
  trap 'rm -f "$registry_entry" "$REGISTRY_DIR/.${registry_entry##*/}.tmp" 2>/dev/null || true' EXIT
  child_command=(env KP_HEADLESS_CHILD=1 KP_RUN_ID="$run_id" KP_CHILD_LOG="$log")
  [ -n "$effort" ] && child_command+=(KP_EFFORT="$effort")
  child_command+=(claude -p "$prompt"
    --permission-mode bypassPermissions --autocompact "$AUTOCOMPACT" --settings "$SETTINGS")
  [ -n "$model" ] && child_command+=(--model "$model")
  [ -n "$effort" ] && child_command+=(--effort "$effort")
  [ -n "$chrome" ] && child_command+=(--chrome)

  cd "$cwd" || { echo "run-child.sh: cannot enter $cwd" > "$log"; echo 1 > "$log.exit"; return; }
  "${child_command[@]}" > "$log" 2>&1 &
  child=$!
  register_child "$child" "$cwd" "$log" "$prompt"
  killer=
  if [ "$timeout_seconds" -gt 0 ]; then
    ( sleep "$timeout_seconds"; sweep_run "$run_id" ) >/dev/null 2>&1 &
    killer=$!
  fi
  wait "$child" || code=$?
  [ -n "$killer" ] && { kill -TERM "$killer" >/dev/null 2>&1 || true; }
  sweep_run "$run_id"
  # Gone before the sentinel, so a caller whose --wait has returned never lists it.
  rm -f "$registry_entry"
  echo "$code" > "$log.exit"
}

# Reads one registry entry into the entry_* globals: one key=value per line, split on
# the first `=` only. Returns 1 when the file cannot be read.
read_entry() {
  local file=$1 line key value
  entry_pid='' entry_epoch='' entry_cwd='' entry_log='' entry_prompt=''
  [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *=*) ;; *) continue ;; esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      pid) entry_pid=$value ;;
      started_epoch) entry_epoch=$value ;;
      cwd) entry_cwd=$value ;;
      log) entry_log=$value ;;
      prompt) entry_prompt=$value ;;
    esac
  done < "$file" || return 1
  [[ $entry_epoch =~ ^[0-9]+$ ]] || entry_epoch=0
}

# <seconds> as HH:MM:SS, or <days>dHH:MM:SS from a day on; negative clamps to 0.
format_elapsed() {
  local total=$1 days
  [ "$total" -lt 0 ] && total=0
  days=$(( total / SECONDS_PER_DAY ))
  if [ "$days" -gt 0 ]; then
    printf '%dd%02d:%02d:%02d' "$days" $(( total / 3600 % 24 )) $(( total / 60 % 60 )) \
      $(( total % 60 ))
  else
    printf '%02d:%02d:%02d' $(( total / 3600 % 24 )) $(( total / 60 % 60 )) $(( total % 60 ))
  fi
}

list_children() {
  local file name sorted now prompt printed=0
  if [ ! -d "$REGISTRY_DIR" ]; then
    echo "no live children"
    return
  fi
  { [ -r "$REGISTRY_DIR" ] && [ -x "$REGISTRY_DIR" ]; } \
    || fail "cannot read the registry directory $REGISTRY_DIR"
  sorted=$(
    for file in "$REGISTRY_DIR"/run-child-*; do
      [ -f "$file" ] || continue
      read_entry "$file" || continue
      printf '%s\t%s\n' "$(( 10#$entry_epoch ))" "${file##*/}"
    done | sort -t $'\t' -k1,1n -k2,2
  )
  now=$(date +%s)
  while IFS=$'\t' read -r _ name; do
    [ -n "$name" ] || continue
    file="$REGISTRY_DIR/$name"
    read_entry "$file" || continue
    if ! [[ $entry_pid =~ ^[0-9]+$ ]] || ! kill -0 "$entry_pid" 2>/dev/null; then
      rm -f "$file"
      continue
    fi
    prompt=${entry_prompt:0:$LIST_PROMPT_CHARS}
    [ "${#entry_prompt}" -gt "$LIST_PROMPT_CHARS" ] && prompt="$prompt…"
    printf 'pid=%s elapsed=%s cwd=%s log=%s prompt=%s\n' "$entry_pid" \
      "$(format_elapsed $(( now - 10#$entry_epoch )))" "$entry_cwd" "$entry_log" "$prompt"
    printed=$(( printed + 1 ))
  done <<< "$sorted"
  [ "$printed" -gt 0 ] || echo "no live children"
}

[ $# -ge 1 ] || usage

if [ "$1" = --list ]; then
  shift
  [ $# -eq 0 ] || usage
  list_children
  exit 0
fi

if [ "$1" = --exec ]; then
  shift
  [ $# -eq 7 ] || usage
  run_detached "$@"
  exit 0
fi

log=
cwd=
model=
model_given=false
effort=
effort_given=false
chrome=
prompt=
wait_only=false
wait_max=$DEFAULT_WAIT_MAX_SECONDS
timeout_minutes=$DEFAULT_TIMEOUT_MINUTES

while [ $# -gt 0 ]; do
  case "$1" in
    --wait) wait_only=true; log=${2-}; shift 2 || usage ;;
    --wait-max-sec) wait_max=${2-}; shift 2 || usage ;;
    --log) log=${2-}; shift 2 || usage ;;
    --cwd) cwd=${2-}; shift 2 || usage ;;
    --model) model=${2-}; model_given=true; shift 2 || usage ;;
    --effort) effort=${2-}; effort_given=true; shift 2 || usage ;;
    --timeout-min) timeout_minutes=${2-}; shift 2 || usage ;;
    --chrome) chrome=chrome; shift ;;
    --) shift; prompt="$*"; break ;;
    *) usage ;;
  esac
done

[ -n "$log" ] || usage
[[ $wait_max =~ ^[0-9]+$ ]] || usage
case "$log" in /*) ;; *) log="$PWD/$log" ;; esac

if [ "$wait_only" = true ]; then
  wait_for_child "$log" "$wait_max"
fi

if [ -z "$cwd" ] || [ -z "$prompt" ]; then usage; fi
[[ $timeout_minutes =~ ^[0-9]+$ ]] || usage
if [ "$effort_given" = true ]; then
  [[ $effort =~ $EFFORT_RE ]] || usage
fi
if [ "$model_given" = true ]; then
  # model-label.sh rejects an empty value or an empty model part with its own usage line.
  split=$("$MODEL_LABEL" "$model") || exit 2
  model=${split#model=}
  model=${model% effort=*}
  [ "$effort_given" = true ] || effort=${split##* effort=}
fi
[ -d "$cwd" ] || fail "no such working directory: $cwd"
[ -f "$SETTINGS" ] || fail "missing headless settings: $SETTINGS"
command -v claude >/dev/null 2>&1 || fail "claude is not on PATH"
mkdir -p "$(dirname "$log")" || fail "cannot create the log directory for $log"

# A previous run's sentinel would make the first wait return at once with a stale code.
rm -f "$log.exit"
: > "$log" || fail "cannot write $log"

nohup "$here/run-child.sh" --exec \
  "$log" "$(( timeout_minutes * 60 ))" "$cwd" "$model" "$prompt" "$chrome" "$effort" \
  >/dev/null 2>&1 &
disown
printf 'status: running log=%s\n' "$log"
exit 3
