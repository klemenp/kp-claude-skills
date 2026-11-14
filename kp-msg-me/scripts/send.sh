#!/usr/bin/env bash
# Send a Telegram message via the Bot API.
# Credentials are resolved in this order:
#   1. Environment: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
#   2. Config file: ${KP_MSG_ME_CONFIG:-$HOME/.config/kp-msg-me/config}
# Usage: send.sh [--session-end] <message...>
set -euo pipefail

CONFIG_FILE="${KP_MSG_ME_CONFIG:-$HOME/.config/kp-msg-me/config}"
HTTP_TIMEOUT=15

print_setup() {
  cat >&2 <<EOF
Telegram credentials are not configured.

One-time setup:
  1. In Telegram, message @BotFather and send /newbot. Follow the prompts to get a
     bot token that looks like 123456789:AAExampleTokenABCdef...
  2. Open a chat with your new bot and send it any message (e.g. "hi"). This lets the
     bot see you and gives you a chat_id.
  3. Find your chat_id by running (replace <TOKEN>):
       curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | grep -o '"chat":{"id":[0-9-]*'
     Use the number after "id":.
  4. Save the credentials. Either export env vars in your shell profile:
       export TELEGRAM_BOT_TOKEN='123456789:AAExample...'
       export TELEGRAM_CHAT_ID='987654321'
     Or create the config file at:
       $CONFIG_FILE
     containing:
       TELEGRAM_BOT_TOKEN=123456789:AAExample...
       TELEGRAM_CHAT_ID=987654321
     Then: chmod 600 "$CONFIG_FILE"
EOF
}

# --session-end marks a session's wrap-up message: a headless child session (one
# kp-gh-lib/scripts/run-child.sh launched, which sets KP_HEADLESS_CHILD) is not where the
# operator waits, so its wrap-up is dropped and only the top-level session's is sent.
if [[ "${1:-}" == "--session-end" ]]; then
  shift
  if [[ -n "${KP_HEADLESS_CHILD:-}" ]]; then
    echo "skipped: headless child session"
    exit 0
  fi
fi

if [[ $# -eq 0 ]]; then
  echo "Error: no message provided. Usage: send.sh [--session-end] <message...>" >&2
  exit 2
fi
MESSAGE="$*"

# Load config file if env vars are not already set.
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$CONFIG_FILE"; set +a
  fi
fi

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
  print_setup
  exit 3
fi

# The URL carries the token, so curl reads it from a config on stdin: an argument would
# be readable by other processes for as long as the call runs. printf is a builtin.
RESPONSE="$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" |
  curl -sS --max-time "$HTTP_TIMEOUT" --config - \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${MESSAGE}")" || {
  echo "Error: failed to reach Telegram API." >&2
  exit 4
}

if printf '%s' "$RESPONSE" | grep -q '"ok":true'; then
  echo "Message sent."
  exit 0
fi

echo "Error: Telegram API rejected the request:" >&2
echo "$RESPONSE" >&2
exit 5
