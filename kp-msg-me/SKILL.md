---
name: kp-msg-me
description: Send a Telegram message to the operator. The message text is the argument. Use when asked to "message me", "ping me on Telegram", "text me", or notify the operator out-of-band (e.g. when a long task finishes). Manual-only.
disable-model-invocation: true
context: fork
model: haiku
argument-hint: <message text>
allowed-tools: Bash(~/.claude/skills/kp-msg-me/scripts/send.sh:*)
---

# Message me on Telegram

Send `$ARGUMENTS` to the operator as a Telegram message via a personal bot.

## Steps

1. **Treat `$ARGUMENTS` as the message.** Everything passed is the literal message text.
   If `$ARGUMENTS` is empty, stop and ask what to send.
2. **Send it** by running the script with the message as a single argument:

   ```bash
   ~/.claude/skills/kp-msg-me/scripts/send.sh "$ARGUMENTS"
   ```

3. **Report the result.** On success the script prints `Message sent.` — confirm that.
   On a non-zero exit, relay the error verbatim. Exit code `3` means credentials are not
   configured yet; in that case relay the printed setup instructions and do not retry
   until the operator has set them up.

## Credentials (one-time setup)

The script reads `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` from the environment, or
from `~/.config/kp-msg-me/config` (override path with `KP_MSG_ME_CONFIG`). To create the
bot: message `@BotFather`, send `/newbot`, save the token; send your bot a message, then
fetch your chat id from `https://api.telegram.org/bot<TOKEN>/getUpdates`. Running the
script without credentials prints these same steps.

## Session-end messages

`send.sh --session-end "<message>"` sends a session's wrap-up only when the session is
top-level: with `KP_HEADLESS_CHILD` set (every child `kp-gh-lib/scripts/run-child.sh`
launches) it prints `skipped: headless child session` and exits 0 without sending. The
`kp-*` orchestrators send their wrap-up this way (`kp-gh-lib/NOTES.md` § *Operator
notifications*).

## Notes

- The script is the only side-effecting part; it has a network timeout and verifies the
  API returned `ok:true` before claiming success.
- Keep secrets out of the skill: never paste the token/chat id into this file or into
  command arguments — they live only in the env or the gitignored config file.
