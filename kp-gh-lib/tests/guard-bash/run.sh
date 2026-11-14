#!/usr/bin/env bash
# Pipes PreToolUse events to .claude/hooks/guard_bash.py and checks the guard's answer:
# empty stdout is "allow", a JSON deny carries its reason. Covers each of the guard's
# eight rules in its usual spelling, the spellings a raw-text match missed, the texts
# that only mention a guarded command (which a raw-text match blocked), ordinary
# commands, and the Write / malformed-event paths. Rule 8 (history on main) runs against
# two temporary repositories, one on `main` and one on a task branch.
# Offline — only local git — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
hook="${GUARD_BASH_HOOK:-$repo_root/.claude/hooks/guard_bash.py}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
checks=0
mismatches=0

main_repo="$work/live"
task_repo="$work/task"
for repo in "$main_repo" "$task_repo"; do
  git init -q "$repo"
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
done
git -C "$main_repo" branch -q -M main
git -C "$task_repo" branch -q -M task/1-x

# answer <cwd> <command> — prints `allow`, or the deny reason.
answer() {
  python3 - "$1" "$2" <<'PY' | python3 "$hook" | reason
import json
import sys
json.dump({"cwd": sys.argv[1], "tool_name": "Bash", "tool_input": {"command": sys.argv[2]}},
          sys.stdout)
PY
}

reason() {
  python3 -c '
import json
import sys
text = sys.stdin.read()
print(json.loads(text)["hookSpecificOutput"]["permissionDecisionReason"] if text.strip() else "allow")
'
}

# expect <label> <cwd> <command> <allow | text the deny reason must contain>
expect() {
  local label=$1 got
  got=$(answer "$2" "$3")
  checks=$((checks + 1))
  if { [ "$4" = allow ] && [ "$got" = allow ]; } \
    || { [ "$4" != allow ] && [[ $got == *"$4"* ]]; }; then
    echo "-> $label: ok"
  else
    echo "-> $label: MISMATCH (want '$4', got '$got')"
    mismatches=$((mismatches + 1))
  fi
}

delete='recursive force delete'
force='force push'
no_verify='--no-verify skips'
protected='writes a protected path'
history="refusing to rewrite history on 'main'"

echo "== each rule, usual spelling"
expect "rm -rf" "$task_repo" 'rm -rf d' "$delete"
expect "push --force" "$task_repo" 'git push --force' "$force"
expect "reset --hard" "$task_repo" 'git reset --hard' 'hard reset'
expect "clean -fd" "$task_repo" 'git clean -fd' 'git clean deletes'
expect "checkout -- ." "$task_repo" 'git checkout -- .' 'discards all local changes'
expect "commit --no-verify" "$task_repo" 'git commit --no-verify -m x' "$no_verify"
expect "redirect to .env" "$task_repo" 'echo x > .env' "$protected"
expect "commit on main" "$main_repo" 'git commit -m x' "$history"

echo "== spellings a raw-text match missed"
expect "rm -r -f" "$task_repo" 'rm -r -f d' "$delete"
expect "rm long options" "$task_repo" 'rm --recursive --force d' "$delete"
expect "rm by full path" "$task_repo" '/bin/rm -fr d' "$delete"
expect "commit -n" "$task_repo" 'git commit -n -m x' "$no_verify"
expect "commit -nm" "$task_repo" 'git commit -nm x' "$no_verify"
expect "hooksPath override" "$task_repo" 'git -c core.hooksPath=/dev/null commit -m x' "$no_verify"
expect "push +refspec" "$task_repo" 'git push origin +main' "$force"
expect "sudo rm -rf" "$task_repo" 'sudo rm -rf d' "$delete"
expect "bash -c rm -rf" "$task_repo" 'bash -c "rm -rf d"' "$delete"
expect "heredoc fed to bash" "$task_repo" $'bash <<\'EOF\'\nrm -rf d\nEOF' "$delete"
expect "later cd onto main" "$task_repo" "cd $task_repo; cd $main_repo && git commit -m x" "$history"

echo "== text that only mentions a guarded command"
expect "quoted rm -rf" "$task_repo" 'echo "rm -rf d"' allow
expect "commit message mentions force push" "$task_repo" \
  'git commit -m "never use git push --force"' allow
expect "heredoc written to a file" "$task_repo" \
  $'cat > notes.txt <<\'EOF\'\nrm -rf d\ngit reset --hard\nEOF' allow
expect "assignment before cd to the task repo" "$main_repo" \
  "X=1; cd $task_repo && git commit -m x" allow
expect "reading .env.example" "$task_repo" 'grep -n token .env.example' allow

echo "== ordinary commands"
expect "rm -r" "$task_repo" 'rm -r d' allow
expect "rm -f" "$task_repo" 'rm -f f' allow
expect "push --force-with-lease" "$task_repo" 'git push --force-with-lease' allow
expect "push a task branch" "$task_repo" 'git push origin task/1-x' allow
expect "clean -n" "$task_repo" 'git clean -n' allow
expect "checkout one file" "$task_repo" 'git checkout -- file.txt' allow
expect "commit on a task branch" "$task_repo" 'git commit -m x' allow
expect "git -C to the task repo" "$main_repo" "git -C $task_repo commit -m x" allow
expect "git -C onto main" "$task_repo" "git -C $main_repo commit -m x" "$history"

echo "== Write events and a malformed event"
write_event() {
  printf '{"cwd": "%s", "tool_name": "Write", "tool_input": {"file_path": "%s"}}' \
    "$task_repo" "$1" | python3 "$hook" | reason
}
checks=$((checks + 3))
if [ "$(write_event notes.md)" = allow ]; then echo "-> Write notes.md: ok"
else echo "-> Write notes.md: MISMATCH"; mismatches=$((mismatches + 1)); fi
if [[ "$(write_event .claude/settings.local.json)" == *"is protected"* ]]; then
  echo "-> Write settings.local.json: ok"
else echo "-> Write settings.local.json: MISMATCH"; mismatches=$((mismatches + 1)); fi
if [ "$(printf 'not json' | python3 "$hook" | reason)" = allow ]; then
  echo "-> malformed event: ok"
else echo "-> malformed event: MISMATCH"; mismatches=$((mismatches + 1)); fi

echo "$checks checks, $mismatches mismatches"
[ "$mismatches" -eq 0 ]
