---
name: kp-do-gh-ready-items
description: Drive every Ready coding item on the shared cross-repo board to merged, unattended, re-sweeping every ~15 min while work is pending (ends when nothing is pending or after --idle-max hours without a launch), skipping and reporting any labelled needs-contract. It first resolves every answered Ready type:decision / type:question item in one batched headless /kp-resolve-spec-decision child, skips other human-gated items, then runs the coding items one stream per repo, concurrent across repos, each in milestone and dependency order, nothing launching while an earlier milestone has open work or awaits its kp-audit-alignment round, each item a headless kp-do-gh-task-loop in its repo's checkout that builds it (kp-do-gh-task) and hands its PR to kp-do-gh-pr-loop, and records its outcome from GitHub. Pings the operator via kp-msg-me for an unblock no filed decision announced, once when it waits on unanswered decisions, and when the pass ends; never for a merge. Owns no build or review logic. Manual-only.
disable-model-invocation: true
argument-hint: [--project <number|owner/number|id>] [--repo <owner/name>] [--only <#,#,…>] [--order <#,#,…>] [--label <name>] [--limit <k>] [--max-fix-cycles <k>] [--spec-repo <owner/repo>] [--idle-max <hours>] [--dry-run]
allowed-tools: Read, Grep, Glob, Bash
model: sonnet
---

# Drive every Ready coding item to merged

Orchestrator for the `kp-*` GitHub family. `kp-do-gh-task-loop` owns the lifecycle of
one issue — it builds it with `kp-do-gh-task` (build → PR → **In review**) and hands the
PR to `kp-do-gh-pr-loop` (the `kp-review-gh-pr` ⇄ `kp-fix-pr` loop → squash-merge →
**Done**, or a blocking decision issue when the loop stops converging). This skill
**walks the whole backlog**: it picks every coding item the operator has marked
**Ready** on the board and drives each one all the way to merged, in dependency
order, unattended. It works in **rounds** (§3.3): once a round's list is done it sweeps
the board again, so work that turned Ready meanwhile — a dependent a merge unblocked, an
item a resolve or audit filed — is driven in the same pass. A round that launches
nothing ends the pass only when nothing is pending (§3.3); otherwise the pass enters
wait mode (§3.4) and sweeps again about 15 minutes later. The board is the operator's **shared cross-repo Project** (the
family's shared-board convention: `[REPO-CODE]` title prefix + `repo:*` label), so
the selected items may live in **different repos** — each item is driven from its
own repo's local checkout.

It **composes** that skill and **owns no implementation or review logic of its own.**
Every code change, board transition, comment, and token report is made by a child
skill in its own **fresh headless `claude -p` session** — this skill only selects,
orders, launches one `kp-do-gh-task-loop` per item, and reads GitHub state to record
the outcome. Because every phase below it runs in a genuinely fresh context at the
model its `model:*` label names, the backlog is processed exactly as if the operator
had typed `/kp-do-gh-task-loop <n>` by hand for each item — one stream per repo, at most
one `kp-do-gh-task-loop` child per repo at a time, the streams running concurrently
across repos (§3).

Runs **inline (no fork)** like its siblings. It blocks on its own children with
foreground `--wait` calls (§3), never `run_in_background` or `Monitor`, and reads each
child's usage-limit line through `run-child.sh` (§3.0), which a fork has not been probed
to print. Its §1 board sweep is one `ready-sweep.sh` call whose output is only the
selected items' lines, so no board JSON or issue body reaches this context.

**Goal (success criteria):** every selected Ready coding item has been driven
through **build → PR loop** to a terminal outcome — **merged** (board Done), or
**parked with a reported reason** (clarity-gate decision issue raised, build/push
failed, the PR loop parked or raised a decision issue, PR closed, deferred on an
unmerged dependency, or deferred while an earlier milestone has open work), or
**stopped on a Claude usage limit** (`capacity-limit`, §3.0 — which ends the pass) —
processed as one stream per repo — at most one `kp-do-gh-task-loop` child per repo at a
time, the streams running concurrently, each stream in milestone and dependency order —
one `kp-do-gh-task-loop` session per item, round after round — a round that launches no
child ends the pass only when nothing is pending (§3.3), and otherwise the pass waits
and sweeps again (§3.4) until `--idle-max` hours pass without a launch — and one
**final summary table** printed for the whole pass.

## Operator notifications (kp-msg-me)

Per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Operator notifications*. The point of an
unattended pass is that the operator walks away — so whenever a step **needs them back**
for something no filed issue already announced, tell them **immediately**, don't bury it
in the §4 table:

```bash
~/.claude/skills/kp-msg-me/scripts/send.sh "<one-line message>"
```

- **Keep it to one line:** repo, issue/PR, what happened, what you need. E.g.
  `shop-app #43 "Export orders CSV": blocked on shop-app #40 (unmerged) — land it first`.
- **Send at the moment the item parks**, then continue to the next item — the pass
  keeps running; the message is a heads-up, not a stop.
- **Once per item or edge per pass.** A later round (§3.3) that defers the same item for
  the same reason, or names the same stalling edge, sends nothing new.
- The events that fire such a message are tagged **→ notify** in §1–§3 — an unmerged
  dependency, a stalling cross-milestone edge (§2.4), no usable checkout, a primary
  checkout that is not clean (§1.7, once per repo per pass), a failed
  audit round. **Never notify** for a merged item or ordinary progress, a waiting
  milestone, a `needs-contract` skip, or a decision that blocks an item or slipped into
  Ready — filing a decision pinged the operator already (`create-item.sh`), including
  an audit-close decision this pass raises. The exceptions are a creator-decided item,
  which never pinged and which §1.8 pings only when its resolve fails, and the
  wait-mode ping below.
- **Wait-mode ping.** The first time in a pass that §3.4 is entered with a non-empty
  pending (a) list (§3.3), send one `send.sh` line naming each `<repo>#d` in it, e.g.
  `Shop board: ready-items waiting on 2 unanswered decisions — shop-api #120, shop-app #41; sweeping every 15 min until <idle-max deadline>`.
  The deadline is the time of the pass's last child launch (or the pass start if none)
  plus `--idle-max`, as of the ping, printed `YYYY-MM-DD HH:MM UTC`. Compute it with
  exactly this command, writing the last-launch epoch seconds §3.4 records and the
  `--idle-max` value in as literal numbers (never `date -d` / `date -r`, which differ
  between GNU and BSD):
  `python3 -c 'import sys; from datetime import datetime, timezone; print(datetime.fromtimestamp(int(sys.argv[1]) + round(float(sys.argv[2]) * 3600), timezone.utc).strftime("%Y-%m-%d %H:%M UTC"))' <last-launch epoch> <idle-max>`.
  It is sent at most once per pass, even if later waits list other items.
- **No per-item message for a §3 outcome.** `kp-do-gh-task-loop` pings its own
  build-side stops (dependency, failed build), and the task-loop's and pr-loop's
  wrap-ups are dropped because they run headless, so each item is messaged at most once.
- **Session wrap-up:** §4 ends with one line through
  `send.sh --session-end "<one-line message>"` — the pass's "done" message.
- **A failed send is not fatal.** If the script exits non-zero (e.g. exit `3` =
  credentials unset), note it **once** in the §4 report and keep going — never retry
  the send and never let it abort the pass.

## 0. Setup

1. **This run's arguments: `$ARGUMENTS` (empty if none). Parse them** (all optional):
   - `--project <number|owner/number|id>` — target board.
   - `--repo <owner/name>` — **filter**: restrict the pass to items of this repo
     (the board is cross-repo; without this flag, items of every repo are selected).
   - `--only <#,#,…>` — restrict to these issue numbers. Numbers may be repo-qualified
     (`owner/name#7` or `name#7`); a bare `#7` is fine when only one repo in the
     selected set has an issue 7 — if it's ambiguous, stop and ask.
   - `--order <#,#,…>` — operator's preferred sequence (a hint layered on top of
     milestone and dependency order — see §2). Same qualified-number forms as `--only`.
     Neither `--order` nor `--only` ever overrides the milestone gate (§2.3).
   - `--label <name>` — extra filter on the selected issues (e.g. a milestone/area label).
   - `--limit <k>` — launch at most `k` items (§3.1) across the whole pass, every
     round counted (§3.3).
   - `--max-fix-cycles <k>` — kept for compatibility: forwarded to `kp-do-gh-task-loop`
     as `--max-cycles <k>` (§3.1), which passes it on to `kp-do-gh-pr-loop`. When
     absent, nothing is forwarded and the pr-loop's own default applies; see its loop
     policy for the meaning and default.
   - `--spec-repo <owner/repo>` — the spec repo an earlier milestone's audit runs
     against (§3), resolved per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Milestone
     sequencing* → *Audit gate*.
   - `--idle-max <hours>` — default `12`; a positive number, decimals allowed (e.g.
     `0.5`). Anything else stops the run with a clear message before §0.2. The pass ends
     once that many hours pass with no child launched (§3.4).
   - `--dry-run` — plan and print the ordered run list, execute nothing. The pass is one
     round, since it launches nothing (§3.3). It never enters wait mode, and its §4
     report prints the pending decision §3.3 would make (`would wait: <pending lines>` or
     `would stop: nothing pending`).
2. **Launch guard + workspace root.** `gh auth status` must succeed; else stop with a
   clear message. **Run from a primary checkout**, not inside a child worktree:
   `~/.claude/skills/kp-gh-lib/scripts/ensure-checkout.sh --here --no-fetch`. Exit `5`
   → stop and tell the operator to run from a primary checkout. A `not clean (` stderr
   line on exit 0 is ignored here: this checkout is notified through §1.7 when it is
   also an item repo's, and is nobody's build checkout otherwise. The **parent directory
   of the path it prints is the workspace root**: every item repo's checkout lives (or
   is cloned) there as
   `<workspace>/<repo-name>`, and the children create their own
   `../<repo-name>-task-<n>` / `../<repo-name>-fix-pr-<n>` /
   `../<repo-name>-review-pr-<n>` siblings inside it.
3. **Sync.** Per-repo fetches happen in §1.7 once the involved repos are known.
4. **Resolve the Project (v2)**, same precedence as the family: `--project` → config
   `.claude/spec-sync.json` (`project`) → otherwise **ask** by listing candidates
   (`gh project list --owner <owner>`, `gh project list --owner @me`) and stopping
   for a selection. Record the project's **owner login and number** (the node id
   comes from §0.5). There is **no single target repo** — the board is cross-repo and
   each item's repo comes from its linked issue (§1); `--repo` only filters. **The
   project is passed to every child run** (`--project <…>`), so no child ever stops to
   ask — that is what makes the children unattended. It skips the child's *selection
   ask* only: `--project` carries an owner and number, never field or option ids, so
   every child still runs its own 3–4 point preamble.

   **Board lock (§0.4a).** Two passes never sweep the same board at once: a pass holds
   the board's run lock from here to §4. Run
   `~/.claude/skills/kp-gh-lib/scripts/run-lock.sh acquire --workspace <workspace> ready-items-<owner>-<number>`
   with `<workspace>` the root from §0.2 (`kp-gh-lib/SKILL.md` § *`run-lock.sh`*).
   `<stderr line>` below means the last non-empty line `run-lock.sh` wrote to stderr,
   or `no error output` when there is none.
   - exit `0` → the pass holds the board. A `takeover=` line means a stale lock from a
     dead pass was taken over; continue, and name the takeover in the §4 report.
   - exit `3` (a live pass holds the board) → stop before §0.5 and §1. Print
     `refused to start: a ready-items pass for <owner>/<number> is already running — pid <pid>, started <started>, log <log>`
     from the `held` line, with `session <session>` in place of `log <log>` when its
     `log=` is empty. Launch no child and make no board or issue change, then send the
     wrap-up `~/.claude/skills/kp-msg-me/scripts/send.sh --session-end "<owner>/<number>: ready-items pass refused to start — pass pid <pid> running since <started>"`.
   - exit `1` or `2` → the same refusal: print
     `refused to start: board lock failed — <stderr line>`, launch nothing, and send the
     wrap-up `~/.claude/skills/kp-msg-me/scripts/send.sh --session-end "<owner>/<number>: ready-items pass refused to start — board lock failed: <stderr line>"`.

   Both refusals are outcome **`refused-to-start`**. §4 does not run for them: the
   refused line and the wrap-up are the pass's whole output, and there is nothing to
   release, because the pass never took the lock. A failed send is noted once, as in §4.

   Once the lock is taken, every stop after this point ends with §4 — each stop in
   §0.5–§3, `capacity-limit` and `idle-max` included, keeps its own stop reason and
   report and goes through §4, whose first step releases the lock. A crashed or killed
   pass leaves a lock whose dead `CLAUDE_PID` the next pass takes over as stale.

   On `--dry-run`, run
   `~/.claude/skills/kp-gh-lib/scripts/run-lock.sh status --workspace <workspace> ready-items-<owner>-<number>`
   instead — a dry run never takes the lock. `status` exits `0` whenever it prints a
   `free`, `held` or `stale` line, so classify by that line: `free` or `stale` prints
   `board lock: free` or `board lock: stale`; `held` prints
   `would refuse: pid <pid>, started <started>, log <log>` (`session <session>` in place
   of `log <log>` when `log=` is empty). Only exit `1` or `2` is a check failure, which
   prints `would refuse: board lock check failed — <stderr line>`. Every case then
   continues the dry-run plan.
5. **Resolve the project id + Status field — 1 point.**
   `~/.claude/skills/kp-gh-lib/scripts/resolve-board.sh <owner> <number>` prints the
   project node id and the `Status` field id with all its option ids (`status` is
   `null` when the board has no such field).

   Confirm the board has a `Ready` option (the board is
   `Backlog · Ready · Blocked · In progress · In review · Done`). If the board has no
   such field or the option is named differently, ask which option maps to "ready"
   before proceeding. `Ready` selects the work; §3 reads outcomes from PR and issue
   state, not board Status.
6. **GitHub API budget (family convention).** Keep this preamble ≤5 points — never
   `gh project field-list` or a board-wide `gh project item-list` — and read the
   remaining budget from `X-RateLimit-Remaining`, never `gh api rate_limit`. A
   secondary-limit `403` is a park/escalate reason, not a crash (stop issuing calls,
   report it, resume later); the rules and their rationale are in
   `~/.claude/skills/kp-gh-lib/NOTES.md`.

   This skill is the one place in the family that legitimately enumerates the whole
   board — §1.1 does it in **3 points**, not 305.

## 1. Collect the Ready items

Steps 1–5 are a read-only sweep whose raw output — the board JSON and every survivor's
issue body — no later step needs, so they run as **one** foreground call:

```bash
~/.claude/skills/kp-gh-lib/scripts/ready-sweep.sh --project <owner>/<number> \
  [--repo <owner/name>] [--only <#,#,…>] [--label <name>] [--status <name>]
```

with the `--repo`, `--only` and `--label` values given in §0.1, and `--status <name>` when
§0.5 mapped "ready" to another option name. Exit `1` or `2` stops the pass with the
script's stderr, as any failed GitHub read does. On exit `0` it prints exactly these lines
and nothing else (`kp-gh-lib/SKILL.md` § *`ready-sweep.sh`*):

```
item <owner/name>#<n> | <title> | <model alias, or opus (no model label)> | <blocked-by markers, comma-separated, or none> | <prefix/label mismatch, or none>
gated <owner/name>#<n> | <title> | <human-gated type label> | <answered-person, answered-agent, unanswered, check:<fallback>, or - (conflict/research)>
needs-contract <owner/name>#<n> | <title>
ambiguous <--only number> | <the repos it matches>
```

For each `check:<fallback>` line, run `~/.claude/skills/kp-gh-lib/scripts/decision-state.sh
<R> <n>` and set field 4 to **`answered-person`** when any `humanCandidates` entry picks an
outcome as `kp-resolve-spec-decision-auto` §2 defines it, else to `<fallback>`, before
step 6. The script never makes that judgment.

An `ambiguous` line stops the run and asks, per §0.1. In a later round (§3.3), first drop
every returned line whose item is in the pass's **driven set**, except the line of an item
that is **re-launchable** (§3.3 step 3), which is kept. Steps 6–8 run here, on the
remaining lines.

1. **Sweep the board — 3 points, ~62 KB.** `ready-sweep.sh` pages one narrow GraphQL
   selection (Status, issue number, repo, state, labels), retrying once as an
   organization on a user-login miss; never `gh project item-list`, which would cost 305
   points and 582 KB here because it returns every field value of every item.
2. **Filter on the sweep's own fields first**, before any per-issue call: it keeps OPEN
   issues in **Ready** (or the `--status` option) carrying `type:coding` or a human-gated
   type, so the join below runs
   over a handful of survivors. Each survivor's repo is its home for every `gh` call and
   child run.
3. **Join the survivors to their issues** with one `gh issue view` each (1 point). The
   issue's actual repo is authoritative; a `[REPO-CODE]` title prefix or `repo:*` label
   that disagrees is reported as the `item` line's mismatch field, for the §4 report, and
   the real repo is driven.
4. **Apply filters**: `--repo` and `--only` (qualified forms per §0.1) before the join,
   `--label` after it. `--limit` stays here: it caps the count at what the pass has left
   of `k` *after* ordering in §2, so the highest-priority items survive the cap.
5. **Capture per item** the model tier — the `model:*` label value, effort suffix
   included (default **`opus`**, "no model label") — and the
   `blocked-by:` markers, read outside the human-only fence: everything from a
   `<!-- human-only:start … -->` marker to its matching `<!-- human-only:end -->` is
   skipped (to end of body if unclosed). A `needs-contract` coding item gets its own
   line; a `type:decision` / `type:question` item's state comes from `decision-state.sh`,
   exactly as `kp-resolve-spec-decision-auto` §2 reads it; a `type:conflict` /
   `type:research` line carries `-`.
6. **Skip human-gated types.** If a `type:decision` / `type:question` /
   `type:conflict` / `type:research` item slipped into Ready, **do not build it**. An
   `answered-person` or `answered-agent` decision or question goes to step 8; every other
   `gated` line is listed in the §4 report as "human-gated, skipped" (filing it already
   pinged the operator; a creator-decided item is never `unanswered`, so none lands
   here), and the pass moves on. **Skip `needs-contract` the same way:** a
   `type:coding` item carrying the `needs-contract` label (step 5 reports it on a
   `needs-contract` line, after the step 4 filters) never gets a build. List it in the
   §4 report as `skipped: needs-contract`, without a notify — a backfill can label many
   items at once, and its own report already names them. Removing the label, by the
   operator or by a `/kp-backfill-contract` pass that converts the body
   or finds the item now passes the lint, makes the item eligible on the next pass.
7. **Resolve a local checkout per involved repo.** For each distinct repo among the
   selected items that no earlier round of this pass resolved, run
   `~/.claude/skills/kp-gh-lib/scripts/ensure-checkout.sh <owner/name> --workspace
   <workspace> --clone` (§0.2's workspace root): it clones a missing
   `<workspace>/<repo-name>`, requires a primary checkout whose `origin` is that repo (a
   worktree here would collide with the children's siblings), fetches it with `--prune`
   and prints the checkout. On any non-zero exit, park **all of that repo's items** as
   **"no usable checkout"** with the script's stderr, **→ notify** (needs the operator
   to unblock), and continue with the other repos' items. Capture its stderr: on exit `0`,
   a line containing `not clean (` means the checkout has local changes or is off its
   default branch, so every fresh read of it exports a worktree and pulls are skipped —
   **→ notify** once per repo per pass:
   `<repo-name> primary checkout <path> is not clean (<reason>) — every fresh read exports a worktree and pulls are skipped; commit, stash or discard, then re-run`.
   The repo's items are still driven (the children build in worktrees from `origin`, so
   the checkout's state does not affect the build), and the line is kept for §4. Any
   other stderr text on exit `0` is ignored.
8. **Resolve the answered decisions and questions** — before §2, so its blocker and
   milestone reads see the issues these close. Collect every `answered-person` /
   `answered-agent` `gated` item `R#n`, ordered by repo then number, and resolve them.
   With a spec repo, **one** child resolves them all and folds them into one spec PR
   (`kp-resolve-spec-decision` § *Batch run*); a pass with exactly one such item launches
   the same command with that one number. With no spec repo, there is one child per repo
   of the items and no spec PR (the **Spec repo** bullet below):
   - **Spec repo.** Resolve it once per pass per `~/.claude/skills/kp-gh-lib/NOTES.md`
     § *Milestone sequencing* → *Audit gate* (`--spec-repo` first). With none, the
     items are resolved through `kp-resolve-spec-decision` § *No-spec-repo branch*, one
     child per repo of the items, each launched with the **Launch and wait** command
     minus `--spec-repo <spec-repo>`, `--cwd` that repo's checkout (resolved with
     `ensure-checkout.sh` as step 7 does, its `not clean (` line included, when step 7
     has not), and log
     `<scratchpad>/resolve-batch-<k>-<repo-name>.log`. The **Capacity check** and
     **Outcome from GitHub** bullets apply unchanged, their notify rules included:
     `resolve-failed` on an `answered-agent` item still notifies, since a creator-decided
     item never pinged at filing. A CLOSED item is **`resolved`** with spec PR `-`. With
     a spec repo, its checkout is `<workspace>/<spec-repo-name>`, cloned, guarded and fetched as step 7
     does a code repo's; a failure gives each item **`no-usable-checkout`**, **→ notify**.
     A `not clean (` line from either kind of checkout is handled exactly as step 7
     handles it, sharing step 7's once-per-repo-per-pass dedup, so a repo resolved by
     both steps sends one message.
   - **`--dry-run`:** the outcome is **`would-resolve`** for each; launch nothing.
   - **Launch and wait** exactly as §3 waits on its children (foreground `--wait` calls,
     `Bash` `timeout: 540000`, never `run_in_background` or `Monitor`), with the
     `kp-resolve-spec-decision-auto` §4.2 command — the resolver is
     `disable-model-invocation`, so only a headless child can run it, and it drives its
     own spec PR's pr-loop before it exits. Every batched item enters the pass's
     **driven set** at launch. `<k>` is the pass's round counter (§3.3), starting at 1;
     `--timeout-min` is 480 plus 120 per batched item beyond the first; the numbers are
     qualified, with no `--repo`:

     ```bash
     ~/.claude/skills/kp-gh-lib/scripts/run-child.sh --log "<scratchpad>/resolve-batch-<k>.log" \
       --cwd <workspace>/<spec-repo-name> --timeout-min <480 + 120 × (items − 1)> \
       -- "/kp-resolve-spec-decision <R1>#<n1> <R2>#<n2> … --spec-repo <spec-repo> --project <project>"
     ~/.claude/skills/kp-gh-lib/scripts/run-child.sh --wait "<scratchpad>/resolve-batch-<k>.log"
     ```
   - **Capacity check** (§3.0) on the batch child's result line: a hit makes every
     batched item still open after it stops **`capacity-limit`** — items it closed before
     stopping keep their GitHub outcome below — records every remaining item, coding or
     gated, `not-attempted`, and goes straight to §4.
   - **Outcome from GitHub, per item**, read as `kp-resolve-spec-decision-auto` §4.3 and
     §4.4 read it (`gh issue view <n> -R <R> --json state,comments`): **CLOSED** →
     **`resolved`**, with the spec PR its `Resolved → …` / `Closed as won't-do …` comment
     names (the shared batch PR for a batched item) and that PR's §4.4 state; **OPEN** with a `Goal recorded → PR <pr-url>` comment from this run
     → **`goal-recorded`**, with that PR's state; **OPEN** with a
     `<!-- kp-resolve-spec-decision:no-decision -->` comment and no decision newer than
     it → **`no-decision`**; **OPEN** otherwise → **`resolve-failed`**, with the log
     path, **→ notify** when the item is `answered-agent` — a creator-decided item never
     pinged at filing, so this is the operator's first word of it. Nothing else here
     notifies, and an `answered-person` item never does: a stop the resolver needs the
     operator for files an issue, which pings itself.

   A coding item a resolve creates is not in this round's selection; the next round
   (§3.3) picks it up once it is Ready.

## 2. Order — milestone and dependency first, operator hint second

1. **Topological sort** on the `blocked-by:` edges among the selected items (the
   family's acyclic dependency convention), nodes keyed `owner/name#n` so same-repo
   and cross-repo edges sort alike, so a blocker always runs before its dependent.
   Among the items the edges leave free, the lower milestone (§2.3) runs first; an item
   with no milestone is unranked and placed by §2.5 alone.
   If a cycle is detected, report it and process the involved items last
   in repo-then-issue-number order (best-effort — don't deadlock).
2. **Defer items blocked on an unmerged dependency.** It runs after §2.3 step 1 and
   reads the item's `blocker-state.sh` entries from it. If an item's blocker `#m` has
   an entry with `done: false` and `#m` is **not in this run's set**, first check
   whether it is a **later-milestone blocker** — its entry has `laterMilestone: true`.
   - When **any** such blocker is a later-milestone blocker, the item's outcome is
     **`stalled-cross-milestone`**: it is not launched this pass, it gets no
     "deferred — blocked on … (unmerged)" line and no notify here, and its edge goes to
     §2.4, which reports and notifies it. Its other unmerged blockers, if any, are listed
     in the same §4 row's note. Landing `#m` early is not the fix — it waits on its own
     milestone.
   - Otherwise the item is not actually ready: report **"deferred — blocked on
     <repo>#m (unmerged)"**, **→ notify** (the operator must land `#m` to unblock it),
     and skip it this pass.

   Never build on an unmerged dependency (global §10). (A `#m` that *is* in
   this run's set is handled by the topological order — it runs and merges first —
   unless it is a later-milestone blocker, which §2.3 step 3 treats as a cross edge.)
3. **Milestone gate.** Milestones run strictly in order, per
   `~/.claude/skills/kp-gh-lib/NOTES.md` § *Milestone sequencing*. The gate depends only
   on the milestone, and each `milestone-gate.sh` call spends three REST searches (30
   requests/min) — one each for the milestone epics, their audits and their
   audit-close decisions, however many milestones exist — and a walk of the earlier
   milestones' trees, so run it once per milestone, never once per item:
   1. **Runs before §2.2.** For each selected item, run
      `~/.claude/skills/kp-gh-lib/scripts/blocker-state.sh <owner/name> <n>` once — it
      reports each of its blockers' `done`, `milestone`, `laterMilestone` and
      `inFlight` (`kp-gh-lib/SKILL.md` § *`blocker-state.sh`*) — and look up the
      item's own milestone with `~/.claude/skills/kp-gh-lib/scripts/milestone-of.sh
      <owner/name> <n>` (1 point), once per issue per run — §2.2 and step 3 reuse the
      results. An item with no milestone is never gated and has no cross edges. An exit
      1 from either gives that item **"deferred — milestone gate failed"** with the
      script's stderr; it is never launched.
   2. For each distinct milestone (the same id, on the same project), run
      `~/.claude/skills/kp-gh-lib/scripts/milestone-gate.sh --project <owner>/<number>
      <owner/name> <n>` once — the project this run resolved in §0 — on its
      first item by repo then number, and give its `waitingOn` and `openEarlier` to every
      item of that milestone. Its `crossEdges` covers that item and the `openEarlier`
      items.
   3. Check every selected item's own edges without the gate — including the items §2.2
      marked `stalled-cross-milestone`: each `blocked-by:` line outside its human-only
      fence whose blocker has an entry with `laterMilestone: true` in step 1's
      `blocker-state.sh` output is a cross edge, read like a `crossEdges` entry, whether
      or not the blocker is itself in this run's set. Its dependent gets `stalled-cross-milestone`, never only
      `waiting-on-milestone`.

   An item whose `waitingOn` is set is **"deferred — waiting on milestone M<k>"**, listed
   with the `openEarlier` items holding it, or with **"audit needed"** when the gate
   reports `auditNeeded: "M<k>"` (all of M<k>'s items closed, no current audit — §3.3 runs
   it). It is **not** notified — waiting needs no
   operator action — and it stays in the run list, because an earlier-milestone item in
   this run may merge first: §3 re-checks the gate just before launching it. A non-zero
   exit from either script is **"deferred — milestone gate failed"** with the script's
   stderr; never launch an item the gate could not decide. `--only` and `--order` never
   override the gate.
4. **Name every stalling edge.** A cross edge is an earlier-milestone item
   blocked by a later-milestone one: each waits on the other, so both milestones stall
   and the gate alone would defer them forever. Report the edges from three sources —
   the `crossEdges` entries, the §2.3 step 3 edges and the edges §2.2 handed over —
   deduplicated by (dependent, blocker), one line and one **→ notify** per distinct edge:
   **"stalled — <issue> (M<j>) blocked-by <blockedBy> (M<k>)"**, followed by the repair
   advice `fix the edge: re-run /kp-sync-spec-tasks (it pulls the blocker forward into the dependent's milestone), or edit the marker to point at the same-or-earlier-milestone item the dependent actually needs`.
5. **Honor `--order` as a tie-breaker** within the freedom the topological and milestone
   order allow — it reorders independent items, it never overrides a dependency edge or
   the milestone gate.
6. **Split into streams.** Partition the ordered list by repo (`owner/name`): each
   repo's stream keeps its items in their §2 order, `--order` breaking ties within a
   stream. §3 runs the streams concurrently, one item at a time within each.
7. **Print the final ordered run list** grouped by stream — one block per repo, its items
   in order (repo · issue · title · model · milestone · any deferral) — so a `--dry-run`
   shows the per-repo stream plan. On **`--dry-run`, stop here** and emit the §4 summary
   with nothing executed — the milestone deferrals and stalling edges show in it.

## 3. Per-repo streams (concurrent across repos)

Run the §2 streams with **at most one `kp-do-gh-task-loop` child per repo** in flight,
the streams concurrent across repos. For each item `#n` (repo `R`, checkout
`<workspace>/<repo-name>` from §1.7) with model alias `M`, the child's log `<log>` is
`<scratchpad>/do-<repo-name>-<n>.log` (use the session scratchpad dir). Write it out as a
literal path in every call — a shell variable set in one `Bash` call is gone in the next.
**The child session runs from the item's checkout** — `kp-do-gh-task-loop` resolves its
repo from the working directory, so `--cwd` is what routes the run to the right repo. Each
child has its own log and `--cwd`, launched exactly as §3.1 shows; nothing else about the
launch changes. The scheduling loop:

1. **Launch step.** For every repo whose stream has no child in flight, take the stream's
   head item — never an item behind it, since items within a repo keep their order — and
   launch it per §3.1 when it is launchable; otherwise the head waits and that stream
   launches nothing this step. The head is launchable when:
   - (a) no `blocked-by:` blocker of it that is in this run's set is still queued or in
     flight in any stream, including **another repo's stream** — a blocker whose child
     has finished, whatever its outcome, no longer holds it (the task-loop refuses an
     unmerged one, as it always has). Edges among items §2.1 reported as a cycle never
     hold a launch, so the best-effort cycle order cannot deadlock; and
   - (b) the **Milestone gate at launch** below lets it through.

   A head the gate defers (`waiting-on-milestone M<k>`, `waiting-on-audit-close #d`,
   `milestone-gate-failed`, `audit: no spec repo`) takes that outcome and leaves its
   stream, and the stream's next item becomes the head.
2. **Wait step.** While two or more children are in flight, wait on each in turn, in
   launch order, with
   `~/.claude/skills/kp-gh-lib/scripts/run-child.sh --wait "<log>" --wait-max-sec 120` as
   an ordinary foreground `Bash` call (`timeout: 540000`) — one call per child, never two
   waits in one call. While exactly one child is in flight, use the plain
   `--wait "<log>"` (default 480 s), re-issued until its result line replaces
   `status: running`, exactly as `kp-do-gh-task-loop` "Child sessions" does. The first
   wait that returns a result line collects that child: run the §3.0 capacity check, then
   §3.2, then go back to the launch step — so the finished child's repo launches its next
   item, and the other repos' waiting heads are re-checked too, since the finished child
   may have freed them. A `status: running` moves on to the next in-flight child.
3. **Round end.** The round ends only when every stream is empty and no child is in
   flight; only then does §3.3 run.

**Never end the turn while a child is still running**, and never reach for
`run_in_background` or `Monitor` (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Waiting in a
headless session*).

**Milestone gate at launch.** Just before launching an item, in every stream, re-run
`milestone-gate.sh` for it (§2.3) — the gate is project-wide, and an earlier-milestone
item may have merged earlier in this pass. With `waitingOn` set, first apply
`~/.claude/skills/kp-gh-lib/NOTES.md` § *Milestone sequencing* → *Audit gate*, with
`<workspace>` as the spec checkout's parent and `R` / `<workspace>/<repo-name>` as the
code repo and root:
- its round cap → **`waiting-on-audit-close #d`**;
- on `auditNeeded`, no audit child launches now: record the milestone as
  **audit pending** together with this head's `R` and `<workspace>/<repo-name>` (the
  first head recorded for a milestone wins — still once per milestone), and the head's outcome is `waiting-on-milestone M<k>` with "audit needed".
  A head the gate defers leaves its stream for this round by design, even when the work
  holding the gate is another repo's child still in flight; the next round re-selects it.
  The audit round itself runs at the round boundary (§3.3), once no `kp-do-gh-task-loop`
  child is in flight — still at most once per milestone per pass;
- `audit: no spec repo` when §0 resolves none.

If `waitingOn` is still set after that, the outcome is **`waiting-on-milestone M<k>`**;
a failed re-check is **`milestone-gate-failed`**. Either way launch nothing for that head
and move to its stream's next item; only `audit-failed M<k>` (§3.3) notifies (a raised
audit-close decision pings when `create-item.sh` files it).

### 3.0 Capacity check

A headless child started after the Claude usage limit is hit prints one line and exits
without touching GitHub — which the state reads below cannot tell from a failed build
or a parked PR. So **after the `--wait` result line arrives and before classifying the
outcome**, read its `capacity=` field (`none` | `session-limit` | `weekly-limit`, with
`reset='<time>'` when the CLI named one), as `kp-do-gh-task-loop` "Child sessions" reads
it. The limit can stop the task-loop itself or any child below it, whose limit line
`kp-do-gh-task-loop` §4 quotes in its output, so the field catches all of them; anything
but `capacity=none` is a hit.

On a hit the item's outcome is **`capacity-limit`** — not a build failure, and not a
park for a human:

- **no** decision issue, **no** board move — the item and its PR stay exactly as the
  child left them, and a later pass resumes through the children's own idempotency;
- **end the pass** — the limit is account-wide, so every later child would hit it too.
  Launch nothing more and record every item still queued in every stream
  `not-attempted`. Then collect every child still in flight with the same in-turn
  waits (§3 step 2), classifying each through §3.0 and §3.2, and only then go to §4.
  Never kill a child, never end the turn while one runs, and never retry a launch or
  wait for the limit to reset;
- **no message of its own:** the §4 wrap-up names the repo, the item/PR and the reset
  time. The children send nothing for it either — their wrap-ups are dropped because
  they run headless.

### 3.1 Drive the item

**Item lock first.** Run
`~/.claude/skills/kp-gh-lib/scripts/run-lock.sh status --workspace <workspace> <repo-name>-<n>`
(§0.2's workspace root; `kp-gh-lib/SKILL.md` § *`run-lock.sh`*). On `held`,
another run is driving the item (`kp-do-gh-task-loop` §0.4): launch nothing for it,
record outcome **`already-running (pid <pid>)`**, add it to the driven set and move on.
A non-zero exit → `outcome-read-failed` with the script's stderr; the item is not
launched. On `--dry-run`, which launches nothing, §3.1 and §3.2 make no `status` read.

Otherwise launch one fresh headless `kp-do-gh-task-loop` session from the item's checkout:

```bash
~/.claude/skills/kp-gh-lib/scripts/run-child.sh --log "<log>" --cwd <workspace>/<repo-name> --timeout-min 600 \
  -- "/kp-do-gh-task-loop <n> --project <project> --model M"
~/.claude/skills/kp-gh-lib/scripts/run-child.sh --wait "<log>"
```

The model stays inside the prompt — it is the task-loop's `--model`, which it passes on
to its children — so `run-child.sh` gets no `--model`. `--timeout-min 600` because one
task-loop covers a build plus a whole PR loop. `run-child.sh` passes
`--permission-mode bypassPermissions`, which is required: the runs below it do git / `gh` / worktree / push
writes with no human present. Append `--max-cycles <k>` inside the prompt only when the
operator passed `--max-fix-cycles <k>` (§0.1); otherwise forward nothing, so the
pr-loop's own default applies. Add the item to the pass's **driven set** at launch.
This is the **only** child §3.1 launches — never a `kp-do-gh-task`, `kp-do-gh-pr-loop`,
`kp-review-gh-pr`, or `kp-fix-pr` session directly. Which phase the item needs, and when its review ⇄ fix loop stops, are the
task-loop's and the pr-loop's calls.

### 3.2 Outcome

After the `--wait` result line arrives, run the **§3.0 capacity check**, then **detect the outcome from
GitHub state, not the log** — never the child's stdout. First run the same §3.1
`run-lock.sh status`. On `held`, the outcome is **`already-running (pid <pid>)`**
whatever `item-outcome.sh` would say — the task-loop refused to run, which leaves no
GitHub trace, so `item-outcome.sh` alone would report `build-failed` — and
`item-outcome.sh` is not called. A different run that took the item's lock after this
pass's own child finished is reported the same way, on purpose: another run is now
driving the item. A non-zero `status` exit → `outcome-read-failed` with the script's
stderr. Otherwise run
`~/.claude/skills/kp-gh-lib/scripts/item-outcome.sh <R> --issue <n> --project
<owner>/<number>` (`kp-gh-lib/SKILL.md` § *`item-outcome.sh`* holds the
first-match ladder; PR numbers are repo-scoped — `<pr>` only means something inside `R`)
and record its `outcome=`, with the `pr=`, `decision=`, `blocker=`, `milestone=` and
`mergeStateStatus=` it reports:

- `merged` → `merged`. Also record the item's state (`gh issue view <n> -R <R> --json
  state`) so the table shows the close-out landed.
- `needs-contract` → `skipped: needs-contract` (labelled after the sweep;
  `kp-do-gh-task-loop` §1.4 step 2 refused it whatever its PR state).
- `blocked-on-decision` → `blocked-on-decision #<decision>`.
- `waiting-on-milestone` → `waiting-on-milestone <milestone>` (the task-loop's own gate
  held it).
- `stalled-cross-milestone` / `blocked-on-dependency` → that outcome with `<blocker>`.
- `parked` → `parked`, with `mergeStateStatus` and the `<log>` path.
- `pr-closed` → `pr-closed`.
- `build-failed` → `build-failed`, with the `<log>` path.
- A non-zero exit → `outcome-read-failed`, with the script's stderr; the stream moves on.

`already-running` is never counted as `build-failed` or parked, is not tagged
**→ notify**, and is not re-launchable under §3.3 step 3 (only `blocked-on-decision`
is), so the item is not launched again in this pass.

A **non-zero child exit code is recorded but is not itself the outcome** — GitHub state
is; a child that crashed after merging still counts as `merged`. None of these outcomes
is tagged **→ notify** — a stop that needs the operator was already messaged by the
task-loop or by the filing of its decision (see "Operator notifications"; a
creator-decided decision sent nothing at filing, which is why §1.8 pings on its failed
resolve). Return to the §3 launch step whatever the outcome, except
`capacity-limit`, which ends the pass (§3.0); when the round ends (§3 step 3), go to
§3.3 *Next round*.

Each child posts its own token-usage comment (the family convention); the
orchestrator **does not** duplicate per-child reporting.

### 3.3 Next round

The board moves while a round runs — a merge moves its dependents to Ready
(`unblock-dependents.sh`), a resolve or an audit files new items, the operator marks more
Ready — so the pass does not end with its first list. It keeps a **driven set**: every
item it launched a child for, in §1.8 or §3.1, keyed `owner/name#n`.
§1.8 decision resolves and audit rounds never run while a `kp-do-gh-task-loop` child is in flight.
The next round's §1.8 resolves run, as always, before §2 and so before any task-loop
launches, and audit rounds run here. After the round ends (no `kp-do-gh-task-loop` child
is in flight):

0. **Run the audit pending rounds.** For each milestone §3 recorded as **audit
   pending**, run one audit round per `~/.claude/skills/kp-gh-lib/NOTES.md`
   § *Milestone sequencing* → *Audit gate*, with `<workspace>` as the spec checkout's
   parent and the `R` / `<workspace>/<repo-name>` recorded with that milestone as the
   code repo and root — a `kp-audit-alignment` child launched and
   waited on in the foreground with `run-child.sh`, one at a time, at most once per
   milestone per pass — then read the gate again. A failed round is `audit-failed M<k>`
   (→ notify); a usage-limit hit is `capacity-limit` and ends the pass (§3.0). The items
   it held were recorded `waiting-on-milestone M<k>` and are re-selected by the next
   round. An audit round run here counts as a launch for step 2's "this round launched
   no child" test.
1. **Stop and go to §4** when §3.1 has launched `--limit <k>` items across the pass, or
   on a `--dry-run` round. `--limit <k>` counts task-loop launches across all streams:
   once the k-th has launched, nothing more launches, the children still in flight are
   waited on and classified (§3 step 2, §3.0, §3.2), and every item still queued in any
   stream is `not-attempted`. A `--dry-run` round still evaluates pending (step 2) and
   prints it in §4.
2. **When this round launched no child** — no §1.8 resolve, no §3.3 audit round, no §3.1
   task-loop — evaluate **pending**. Stop and go to §4 only when all four lists below
   are empty; otherwise go to §3.4 *Wait mode*, except as (d) says.
   - **(a) Unanswered human-gated items.** First, every `#d` this pass recorded as
     `blocked-on-decision #d` (§3.2) whose issue is still `OPEN` (`gh issue view <d> -R
     <R> --json state`, `<R>` being the decision's own repo as the
     `blocked-on-decision <R>#<d>` outcome or the `gated` line names it). Second, every
     `gated` line from this round's §1 reply marked `unanswered` or `-` whose issue body
     carries a `blocks:` marker outside its human-only fence (`gh issue view <d> -R <R>
     --json body`, read with the §1.5 fence rule).
   - **(b) Deferred behind in-flight work.** Every item this round recorded as
     `deferred-blocked` (§2.2) or `blocked-on-dependency` (§3.2) that has a blocker in
     flight: a fresh `~/.claude/skills/kp-gh-lib/scripts/blocker-state.sh <R> <n>` for
     the item has an entry with `done: false` and `inFlight: true`.
   - **(c) Open work in the current milestone.**
     `~/.claude/skills/kp-gh-lib/scripts/milestone-gate.sh --project <owner>/<number>
     --current` prints a non-null `milestone` `M<k>`, and `milestone-gate.sh --project
     <owner>/<number> --milestone M<k>` prints `"done": false`. A non-zero exit from
     either is reported in §4 and counts as not pending for (c). Skip (c) when `--only`
     was given; it still applies under `--repo` / `--label`, since the milestone gate is
     project-wide. (c) waits without a ping by design — only (a) pings — and is bounded
     by `--idle-max`.
   - **(d) A newly re-launchable item** (step 3) exists — one that was **not** a
     candidate in this round's §2 and has not triggered (d) before in this pass, so a
     decision that closed after this round's sweep still gets its item re-launched
     instead of the pass stopping. Record every item that triggers (d), keyed
     `owner/name#n`; a recorded item is never (d) again in this pass, whether or not a
     later §1 sweep returns it (§1 may filter it out every round — relabelled
     `needs-contract` by the resolver's sync, or closed by the operator). Unlike
     (a)–(c), (d) does not enter §3.4: the next round starts at once, with no wait. A
     re-launchable item that was a candidate this round and was deferred (e.g.
     `blocked-by:` a spec PR still unmerged, or `waiting-on-milestone`), or that already
     triggered (d), is not (d); it counts under (b) or (c) as usual, or under nothing,
     and goes to §3.4 (or §4), where the `--idle-max` check applies.
3. **Otherwise start the next round** at §1, with the same `ready-sweep.sh` arguments; §0 is not
   repeated. Every item in the driven set is dropped from the sweep, whatever its outcome
   — a parked, failed or decision-blocked item needs the operator, and re-driving it
   every round would never end — with one exception, a **re-launchable** item. An item
   is re-launchable when its last §3.2 outcome was `blocked-on-decision #d`, `#d` is now
   `CLOSED` (`gh issue view <d> -R <R> --json state`), and the pass has not re-launched
   it yet. It stays a candidate even when the next §1 sweep no longer returns it as Ready
   (a stop mid-build may have left it In progress — for a re-launchable item that Status
   counts as launchable). Its sweep line is not reused stale: the next round rebuilds it
   from a fresh `gh issue view <n> -R <R> --json body,labels,state` (model label and
   `blocked-by:` markers re-read), so §2 orders and gates it as usual and §3.1 may launch
   it once more. After that second launch it is dropped for the rest of the pass,
   whatever its outcome. Record each re-launch so §4 can show it. An item that was only
   deferred or waiting (never launched) is selected again, since this round's launches
   may have freed it.
4. A milestone's audit round still runs at most once per pass (§3.3 step 0), and a **→ notify**
   fires at most once per item or edge per pass ("Operator notifications").

A round that launches grows the driven set, spends a re-launch, or spends a milestone's
one audit round. A round that launches nothing either stops or waits, and `--idle-max`
bounds the total wait (§3.4) — except a (d) round, which skips the wait, and each item
triggers (d) at most once per pass (step 2 records it). So the pass ends.

### 3.4 Wait mode

The pass waits here while work is pending (§3.3 step 2) but nothing this pass can launch
yet — a decision the operator has not answered, a blocker still in flight, open work in
the current milestone.

- **Track the last launch.** At the pass's start (§0) and at every child launch (§1.8,
  §3.3 audit round, §3.1), record the epoch seconds of the last launch with `date +%s`.
  Write it as a literal number in later calls, because shell variables do not persist
  between `Bash` calls.
- **Idle limit first.** On entry, when `now − last launch ≥ idle-max × 3600`, stop and
  go to §4 with stop reason `idle-max`.
- **Ping when due.** Otherwise send the wait-mode ping when it is due (see "Operator
  notifications") — at most once per pass, and only with a non-empty pending (a) list.
- **Wait about 15 minutes** as **two** foreground `Bash` calls, each with
  `timeout: 540000`, never `run_in_background` or `Monitor`. Each call runs exactly
  `end=$(( $(date +%s) + 450 )); until [ "$(date +%s)" -ge "$end" ]; do sleep 5; done`,
  the `until` loop `~/.claude/skills/kp-gh-lib/NOTES.md` § *Waiting in a headless
  session* allows (a bare `sleep <n>` is refused).
- **Then start the next round** at §1, §1.8 included, with the same `ready-sweep.sh` arguments.
  §0 is not repeated. Count the wait for §4.
- A usage-limit hit during the next round still ends the pass at once (§3.0,
  unchanged). Wait mode never waits out a capacity limit.

## 4. Final report

**Release the board lock first** — only when §0.4a took it, so never on `--dry-run` and
never after a refusal:
`~/.claude/skills/kp-gh-lib/scripts/run-lock.sh release --workspace <workspace> ready-items-<owner>-<number>`.
A non-zero exit is noted once in the report and never changes the stop reason. A
§0.4a takeover of a stale lock is named in the report too.

Print one table for the whole pass — **round | repo | item | title | model | outcome**,
one row per item at the last round that selected it — where `outcome` ∈
`{merged, resolved, goal-recorded, no-decision, resolve-failed, would-resolve,
blocked-on-decision #d, blocked-on-dependency, stalled-cross-milestone,
build-failed, parked, pr-closed, outcome-read-failed, already-running (pid N),
deferred-blocked, waiting-on-milestone M<k>, waiting-on-audit-close #d, audit-failed M<k>,
audit: no spec repo, milestone-gate-failed, human-gated-skipped,
skipped: needs-contract, no-usable-checkout, capacity-limit, not-attempted}`, and list
every §2.4 stalling edge below it, then one line per repo whose checkout §1.7 or §1.8
found not clean, `not clean: <repo-name> <path> (<reason>)` — a note, not an item
outcome. A §1.8 row shows `-` for model and names its spec
PR with that PR's state, and the row of each item §3.3 re-launched carries a
`relaunched` note. Follow it with the **stop reason** — `nothing pending`, `idle-max`,
`limit`, `capacity-limit` or `dry-run` — the number of rounds, the number of waits
(§3.4) and the total wait time, the pending lists (§3.3 step 2) at the last stop or
`--dry-run` round (`would wait: <pending lines>` or `would stop: nothing pending` on a
dry run), counts (**merged / resolved / parked**) and the scratchpad **log path** for
every non-merged, non-resolved item so the operator can pick up where the loop left
off — for an `already-running` item, the holder's log from the `held` line. This skill makes **no board edits of its own** — every status
transition was made by a child skill.

**Then send the session wrap-up** (`send.sh --session-end`, per "Operator
notifications") — one line saying the pass is done, with the counts and how many items
need the operator. E.g. `Shop board: ready-items pass done — 3 rounds, 4 merged (shop-app 3, shop-api 1), 2 parked (1 decision, 1 build failed).`
Send it once, after the last round, on every completed pass, including a `--dry-run`
(say so) and a pass where nothing was selected; a failed send is noted once and never
aborts the pass. A pass may end on `idle-max`; that line then names what was still
pending. E.g.
`Shop board: ready-items pass ended on idle-max (12h without a launch) — 2 rounds, 1 merged; still pending: shop-api #120 unanswered, M2 open work.`
On a `capacity-limit` pass (§3.0) this wrap-up is the hit's only message, so it also names
the item/PR that hit the limit and the reset time. E.g.
`Shop board: ready-items pass stopped — Claude usage limit on shop-app #42 (PR #88), resets 2:30am (Europe/Berlin); 2 merged, 3 not attempted.`

## Invariants

- **Owns no build or review logic.** Every code change, verdict, merge, board
  transition, PR comment, decision issue, and token report is performed by a child
  `kp-do-gh-task-loop` session (and, below it, `kp-do-gh-task` / `kp-do-gh-pr-loop` /
  `kp-review-gh-pr` / `kp-fix-pr`); this skill only selects, orders, launches, and
  reads GitHub state. The one exception is the milestone audit gate (§3, §3.3): it launches a
  `kp-audit-alignment` child and, after six rounds, files the single audit-close
  decision itself. An answered Ready decision or question is resolved by one batched
  headless `kp-resolve-spec-decision` child per round (§1.8), never by this skill.
- **Fresh context per item and per phase.** Each item is a separate headless
  `/kp-do-gh-task-loop …` child launched with `kp-gh-lib/scripts/run-child.sh`, which in
  turn runs each build and PR loop as its own fresh session — never a reused context,
  always at the item's `model:*` tier (default `opus`), passed unchanged as the
  task-loop's `--model <tier>`, effort suffix included.
- **Dependency order is law.** A `blocked-by:` blocker always runs before its
  dependent — same-repo (`#m`) and cross-repo (`owner/repo#m`) edges alike; an item
  blocked on an unmerged out-of-run dependency is deferred, never built. A blocker in
  another repo's stream holds its dependent until the blocker's child has finished.
  `--order` only breaks ties the topology leaves open.
- **Milestone order is law.** No item launches while an earlier milestone has an open
  non-epic item: the gate is checked when ordering (§2.3) and again just before every
  launch in every stream (§3), `--only` and `--order` never override it, a milestone is done only once
  audited (no seventh audit round ever runs for it), a wait is reported without a ping,
  and a stalling cross-milestone edge is named (§2.4) rather than deferred forever.
- **No build without a contract.** An item labelled `needs-contract` is never launched;
  the report lists it as `skipped: needs-contract`.
- **Each item is driven from its own repo's checkout.** The board is cross-repo;
  every child session `cd`s into `<workspace>/<repo-name>` (auto-cloned via
  `gh repo clone` when missing) and every `gh` read is repo-qualified (`-R`) — a
  bare issue/PR number never crosses repos.
- **Bounded fix loop — delegated.** When the review⇄fix loop stops is
  `kp-do-gh-pr-loop`'s policy (falling findings, stall limit, cycle ceiling); this
  skill never re-implements or overrides it, and only forwards `--max-fix-cycles <k>`
  to `kp-do-gh-task-loop` as `--max-cycles <k>`.
- **One stream per repo, unattended.** At most one `kp-do-gh-task-loop` child per repo
  is in flight, the streams run concurrently across repos, and §1.8 resolves and audit
  rounds run only while no task-loop child is in flight. Children run detached through
  `run-child.sh` and are waited on in the foreground in turn, and never stop to ask
  (project/repo are passed in), so the whole pass runs with no human present.
- **Outcome from GitHub state, not logs, not exit codes.** Item outcomes are read from
  PR state, issue state, `blocked-by:` blockers not yet done, and open decision issues blocking
  the item or its PR — never parsed from child stdout or inferred from a child's exit
  status. The one log read is the §3.0 capacity check, which runs before
  any of them.
- **A capacity hit is not a park.** A child that exits on the Claude usage limit is
  `capacity-limit`: no decision issue, no board move, the pass ends
  cleanly, and exactly one message (the §4 wrap-up, with the reset time) is sent —
  never a retry or wait loop.
- **One live pass per board**, held by the §0.4a lock and released in §4.
- **Launch from a primary checkout**, never inside a child worktree — its parent
  directory is the workspace root where per-repo checkouts and the children's
  worktree siblings live.
- **Operator is pinged only when needed and on completion.** Composing `kp-msg-me`,
  the pass sends a Telegram message the moment an item parks for an unblock
  intervention no filed decision already announced (tagged **→ notify**) and one
  `--session-end` wrap-up when the pass finishes (§4); merged items, progress and
  blocking decisions never notify (§1.8's failed resolve of a creator-decided item, which
  never pinged at filing, and the one wait-mode ping per pass listing the unanswered
  human-gated items §3.4 waits on, are the two gated events that do), a §3 outcome never
  gets a per-item message from this skill, and a failed send never aborts the pass.
- **Repeats while work is pending.** A pass stops on a round that launches nothing only
  when nothing is pending (§3.3), waits otherwise (§3.4), and ends after `--idle-max`
  hours with no launch, or once `--limit` is spent. Within a pass an item in the driven
  set is selected again only once, after its blocking decision closes; a deferred or
  waiting one is selected again every round.
- **Idempotent/resumable through the children.** Re-running re-collects Ready items
  and re-drives each; the children's own check-before-create idempotency (existing
  worktree/branch/PR, single review, no re-merge of a merged PR) means a re-run
  resumes rather than duplicating work.
