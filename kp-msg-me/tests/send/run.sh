#!/usr/bin/env bash
# Drives kp-msg-me/scripts/send.sh with the `curl` stub in bin/ first on PATH: credentials
# from the environment and from the config file, none at all, a rejected request, a
# network failure, and --session-end inside and outside a headless child. The stub
# records its arguments and its standard input, so the suite can check that the bot token
# reaches curl only through stdin. $HOME is an empty temp directory and KP_MSG_ME_CONFIG a
# temp file, so the operator's real credentials are never read; the token is invented.
# Offline — no Telegram — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-msg-me/scripts/send.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home"
export HOME="$work/home"
export PATH="$here/bin:$PATH"
export KP_MSG_ME_CONFIG="$work/config"
export SEND_CURL_ARGS="$work/args" SEND_CURL_STDIN="$work/stdin"
unset TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID KP_HEADLESS_CHILD
token='111111:INVENTED-fixture-token'
chat='424242'
sent='{"ok":true}'
failures=0

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

# run <args…>: runs send.sh with a fresh call record, leaving stdout, stderr and the exit
# status in $out, $err and $status. Set the environment for one run with `VAR=… run …`.
run() {
  rm -f "$SEND_CURL_ARGS" "$SEND_CURL_STDIN"
  out=$("$script" "$@" 2>"$work/stderr")
  status=$?
  err=$(cat "$work/stderr")
  echo "   send.sh $* -> exit $status${out:+: $out}"
}

curl_called() {
  [ -e "$SEND_CURL_ARGS" ]
}

url_line="url = \"https://api.telegram.org/bot$token/sendMessage\""

# 1. Credentials from the environment: the token reaches curl through stdin only.
rm -f "$KP_MSG_ME_CONFIG"
TELEGRAM_BOT_TOKEN=$token TELEGRAM_CHAT_ID=$chat SEND_CURL_RESPONSE=$sent run "build finished"
if [ "$status" -eq 0 ] && [ "$out" = "Message sent." ] \
  && ! grep -qF "$token" "$SEND_CURL_ARGS" \
  && [ "$(cat "$SEND_CURL_STDIN"; echo x)" = "$url_line"$'\n'x ] \
  && grep -qxF "chat_id=$chat" "$SEND_CURL_ARGS" \
  && grep -qxF "text=build finished" "$SEND_CURL_ARGS"; then
  check "token only on stdin" ok
else
  check "token only on stdin" MISMATCH
fi

# 2. Credentials from the config file only.
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID=%s\n' "$token" "$chat" >"$KP_MSG_ME_CONFIG"
SEND_CURL_RESPONSE=$sent run "from the config file"
if [ "$status" -eq 0 ] && [ "$(cat "$SEND_CURL_STDIN")" = "$url_line" ] \
  && ! grep -qF "$token" "$SEND_CURL_ARGS"; then
  check "credentials from the config file" ok
else
  check "credentials from the config file" MISMATCH
fi

# 3. No credentials anywhere.
rm -f "$KP_MSG_ME_CONFIG"
SEND_CURL_RESPONSE=$sent run "nobody to tell"
if [ "$status" -eq 3 ] && ! curl_called; then
  check "no credentials" ok
else
  check "no credentials" "MISMATCH (exit $status)"
fi

# 4. Telegram rejects the request.
rejected='{"ok":false,"description":"Bad Request"}'
TELEGRAM_BOT_TOKEN=$token TELEGRAM_CHAT_ID=$chat SEND_CURL_RESPONSE=$rejected run "rejected"
if [ "$status" -eq 5 ] && [[ $err == *"$rejected"* ]]; then
  check "rejected request" ok
else
  check "rejected request" "MISMATCH (exit $status)"
fi

# 5. The network call itself fails.
TELEGRAM_BOT_TOKEN=$token TELEGRAM_CHAT_ID=$chat SEND_CURL_EXIT=7 run "unreachable"
if [ "$status" -eq 4 ]; then
  check "network failure" ok
else
  check "network failure" "MISMATCH (exit $status)"
fi

# 6. A headless child's wrap-up is dropped.
TELEGRAM_BOT_TOKEN=$token TELEGRAM_CHAT_ID=$chat KP_HEADLESS_CHILD=1 SEND_CURL_RESPONSE=$sent \
  run --session-end "child done"
if [ "$status" -eq 0 ] && [ "$out" = "skipped: headless child session" ] && ! curl_called; then
  check "session end in a headless child" ok
else
  check "session end in a headless child" MISMATCH
fi

# 7. A top-level session's wrap-up is sent.
TELEGRAM_BOT_TOKEN=$token TELEGRAM_CHAT_ID=$chat SEND_CURL_RESPONSE=$sent \
  run --session-end "session done"
if [ "$status" -eq 0 ] && curl_called && grep -qxF "text=session done" "$SEND_CURL_ARGS"; then
  check "session end at the top level" ok
else
  check "session end at the top level" MISMATCH
fi

if [ "$failures" -eq 0 ]; then
  echo "all send checks passed"
else
  echo "$failures send check(s) failed"
  exit 1
fi
