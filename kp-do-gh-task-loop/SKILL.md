---
name: kp-do-gh-task-loop
description: Drive one given GitHub work item to merged, unattended, whatever its board status — first decide from GitHub state where it stands (closed → verify the close-out; not type:coding, labelled needs-contract, a blocked-by blocker that is not done, an open decision issue blocking it, or an earlier milestone with open work → stop and report; an earlier milestone done but unaudited → run a headless kp-audit-alignment round, or after six raise an audit-close decision; an open or merged PR → straight to the PR loop; otherwise build), then run kp-do-gh-task in a fresh headless session at the item's model:* tier, then runs the PR's review ⇄ fix loop with pr-loop.sh, which owns the loop's children, its stop policy, the merge, the close-out, and the PR's escalation. Composes kp-do-gh-task and pr-loop.sh plus kp-msg-me — pings the operator on Telegram when the build side needs them (not for a filed decision), plus a wrap-up only when top-level. Owns no build or review logic. Manual-only.
disable-model-invocation: true
argument-hint: [item-number] [--project <number|owner/number|id>] [--spec-repo <owner/repo>] [--model <tier>] [--max-cycles <k>] [--dry-run]
allowed-tools: Read, Grep, Glob, Bash
model: sonnet
---

# Drive one item to merged

Orchestrator for a **single work item**. Two phases own its lifecycle —
`kp-do-gh-task` (build → PR → **In review**) and the PR's review ⇄ fix loop, run with
`~/.claude/skills/kp-gh-lib/scripts/pr-loop.sh` (the `kp-review-gh-pr` ⇄ `kp-fix-pr`
loop → squash-merge → **Done**, or a blocking decision issue when the loop stops
converging). This skill takes **one item, in any board Status**, works out from GitHub
state which phase it is in, and drives it from there to a terminal outcome.
`kp-do-gh-ready-items` launches it once per selected item; the operator can launch it
for any single item by hand.

It **composes** `kp-do-gh-task` and `pr-loop.sh` and **owns no implementation, review,
or loop logic of its own.** Every code change, verdict, merge, board transition,
comment, and token report is made by a child skill in its own **fresh headless
`claude -p` session** — the build child this skill launches, or the review, fix and
escalate children `pr-loop.sh` launches; this skill only reads GitHub state, launches
the build, runs the script, and reports. It never launches `kp-review-gh-pr` or
`kp-fix-pr` itself: when the review ⇄ fix loop stops is the policy in
`kp-do-gh-pr-loop/SKILL.md` § *Loop policy*, which `pr-loop.sh` carries out.

Runs **inline (no fork)** like its siblings. It is normally itself a headless child of
`kp-do-gh-ready-items`, which is why it blocks on its own children with a foreground
wait ("Child sessions") rather than a background notification. That parent reads the
`capacity=` field `run-child.sh` reports for this skill's log, which quotes the CLI's
usage-limit line (`kp-do-gh-ready-items` §3.0) — a line a fork has not been probed to
print.

**Goal (success criteria):** the item reaches a terminal outcome — **merged** (PR
merged, item closed, board Done), **stopped with a reported reason** (closed without a
merged PR, not a coding item, labelled `needs-contract`, blocked on an open dependency
or decision issue, waiting on an earlier milestone or its audit, build failed, the PR
loop parked or failed, PR closed or draft), or **stopped on a Claude usage limit** (`capacity-limit`) — each phase a fresh
headless session at the right model.

## Operator notifications (kp-msg-me)

Per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Operator notifications*. When the build side
**needs the operator back** for something no filed issue already announced, tell them
immediately:

```bash
~/.claude/skills/kp-msg-me/scripts/send.sh "<one-line message>"
```

- **One line:** repo, item, what happened, what you need. E.g.
  `shop-app #42 "Add wishlist page": blocked on shop-app #40 (unmerged) — land it first`.
- The events that fire such a message are tagged **→ notify** in §1–§3. A decision that
  blocks the item never does: filing it pinged the operator already (`create-item.sh`),
  whether `kp-do-gh-task`'s clarity gate or anyone else filed it — or, for a
  creator-decided item that never pinged, `kp-do-gh-ready-items` §1.8 pings when its
  resolve fails. Nor does a merge, a
  closed, non-coding or `needs-contract` item, a wait on an earlier milestone or an open
  audit-close decision, or any §3 PR outcome other than `pr-loop-failed`.
- **Session wrap-up:** §4 ends with one line through
  `send.sh --session-end "<one-line message>"`, which reaches the operator only when
  they launched this run; as a `kp-do-gh-ready-items` child the script drops it. The PR
  outcome is part of this wrap-up.
- **A failed send is not fatal.** A non-zero exit (e.g. `3` = credentials unset) is
  noted **once** in the §4 report — never retried, never aborting the run.

## 0. Setup

1. **This run's arguments: `$ARGUMENTS` (empty if none). Parse them.** The first bare token is the **item number** (required; if
   missing, stop and ask for one). Then:
   - `--project <number|owner/number|id>` — the GitHub Project (v2).
   - `--spec-repo <owner/repo>` — the spec repo an earlier milestone's audit runs
     against (§1.4 step 5); else `specRepo` in this checkout's `.claude/spec-sync.json`,
     else this checkout when it holds spec docs — resolved per
     `~/.claude/skills/kp-gh-lib/NOTES.md` § *Milestone sequencing* → *Audit gate*.
   - `--model <tier>` — model tier for every child: a model alias that may carry an
     effort (`opus`, `opus-xhigh`), passed on unchanged to `run-child.sh` and
     `pr-loop.sh`, which split it; default is the item's **`model:*`** label value,
     else **`opus`** (family rubric).
   - `--max-cycles <k>` — passed to `pr-loop.sh start` as `--max-cycles <k>` (§3).
     When absent, nothing is passed and the script's own default applies.
   - `--dry-run` — print the resolved plan (item, model, project, the §1.4 entry
     decision and the children it would launch) and execute nothing.
2. **Primary-checkout guard.** §0.3's preamble guards the repo and auth; this skill
   additionally refuses to run **inside a child worktree**:
   `~/.claude/skills/kp-gh-lib/scripts/ensure-checkout.sh --here --no-fetch` (§0.3
   fetches). Exit `5` → stop and tell the operator to run from the item's primary
   checkout, where the children create their `../<repo-name>-task-<n>` /
   `../<repo-name>-*-pr-<n>` siblings.
3. **Preamble — one call.** `~/.claude/skills/kp-gh-lib/scripts/preamble.sh --issue <n>
   [--project <…>]`, then do what `kp-gh-lib/SKILL.md` § *`preamble.sh`* says with its
   JSON, its exit code, and any `null` board field.

   `<R>` is `.repo` — every `gh` read below is `-R <R>`, so a bare issue/PR number
   never crosses repos. Keep `.project.owner`, `.project.number` and the
   **`In review`** id from `.status.options` (§2 reads it). **Every child run is passed
   `--project <owner>/<number>`** so no child ever stops to ask.
4. **Item lock.** Two runs must never drive the same item at once. The workspace
   `<workspace>` is the parent directory of the path §0.2's `ensure-checkout.sh --here
   --no-fetch` printed, and `<repo-name>` is the name part of `<R>`. Run
   `~/.claude/skills/kp-gh-lib/scripts/run-lock.sh acquire --workspace <workspace> <repo-name>-<n>`
   (`kp-gh-lib/SKILL.md` § *`run-lock.sh`*):
   - exit `3` → outcome **`already-running`**: print the holder's pid, start time and
     log (or its session id when log is empty) from the `held` line, then stop through
     §4. Make no board move, post no comment, launch no child, send no `kp-msg-me`
     message and send no `--session-end` wrap-up.
   - exit `1` or `2` → outcome **`lock-failed`** with the stderr line; stop through §4,
     likewise with no board move, comment or message.
   - exit `0` → the lock is held until §4 releases it. A `takeover=` on the line is
     reported in §4.

   Stops in §0.1–§0.3 come before the lock exists: they skip `release` and are
   otherwise unchanged. From here on, every "report and stop" in §1–§3 goes through §4,
   which releases the lock; a crashed or killed session leaves its lock behind with a
   dead `CLAUDE_PID`, which the next `acquire` takes over as stale.

   On `--dry-run`, run `~/.claude/skills/kp-gh-lib/scripts/run-lock.sh status --workspace <workspace> <repo-name>-<n>`
   instead, print its line in the plan (a `held` line adds `would stop: already-running
   (pid <pid>)`), and continue the dry-run plan whatever it printed. A dry run never
   takes the lock.

## 1. Read the item and decide where it stands

1. **Read the issue.** `gh issue view <n> -R <R> --json
   number,title,body,labels,state,url`. Capture the **type label**, the **`model:*`**
   label (→ model tier `M` per §0.1, effort suffix included and passed on unchanged;
   note "no model label" when absent), its **`spec-ref:`**
   (if any), and its **`blocked-by:`** markers — `#m` (an issue in `<R>`) or the
   cross-repo `<owner>/<repo>#m`. Read markers from the body **outside** the human-only
   fence: skip everything from a `<!-- human-only:start … -->` marker (match it
   loosely) to its matching `<!-- human-only:end -->`, dropping to the end of the body
   if unclosed.
2. **Find the item's PR** — `~/.claude/skills/kp-gh-lib/scripts/find-task-pr.sh <R>
   <n>`. Its `pr` is the item's PR (the **open** one, else the **merged** one) or
   `null`, and `closed` lists the PRs closed unmerged, which are never the item's PR.
3. **The open-decision check** (used here and in §2). An item is blocked on decision
   `#d` when an **open** issue in `<R>` labelled `type:decision`, `type:question`, or
   `type:conflict` carries, outside its human-only fence, a `blocks:` marker naming
   this item (`#<n>` or `<R>#<n>`), its open PR (`<R>#<pr>`), or the item's `spec-ref:`
   value — or when the item has a "blocked on #<d>" comment
   (`gh issue view <n> -R <R> --json comments`) pointing at such an issue. Find the
   marker case with **one** call, never by listing every open decision body:
   ```bash
   ~/.claude/skills/kp-gh-lib/scripts/find-blocking-decision.sh <R> --issue <n> \
     [--pr <pr>] [--spec-ref <spec-ref>]
   ```
   dropping the flags the item lacks. Its `decision` (the lowest open human-gated
   issue whose `blocks:` names a target, or `null`) is `#d`; the script applies the
   type labels, both reference forms and the fence. The comment case stays a read of
   the comments — the script does not read them.
4. **Entry decision — first match wins, keyed on GitHub state, never on board
   Status:**
   1. **Item `CLOSED`.** If §1.2 found a **merged** PR → **§3** on it
      (`pr-loop.sh start` on a merged PR only verifies and completes the close-out).
      Otherwise → outcome **`closed-unmerged`**; report and stop.
   2. **Not `type:coding`** (`type:decision` / `type:question` / `type:conflict` /
      `type:research` / `type:epic`, or no type label) → outcome **`not-coding`**;
      report and stop. No child is launched — human-gated items are resolved with
      `/kp-resolve-spec-decision`, epics through their children. A `type:coding` item
      labelled **`needs-contract`** (its body does not meet
      `~/.claude/skills/kp-gh-lib/NOTES.md` § *Coding item body*) → outcome
      **`skipped: needs-contract`**; report and stop, launching nothing, whatever its PR
      state. Once the label is removed — by the operator, or by a
      `/kp-backfill-contract` pass that converts the body or finds the
      item now passes the lint — the item is eligible again.
   3. **A `blocked-by:` blocker is not done** — one call,
      `~/.claude/skills/kp-gh-lib/scripts/blocker-state.sh <R> <n>`, reports every
      blocker (`kp-gh-lib/SKILL.md` § *`blocker-state.sh`*); any entry with
      `done: false` triggers this step. A non-zero exit → outcome
      **`milestone-gate-failed`** with the script's stderr, and stop.
      - Any not-done entry has `laterMilestone: true` → outcome
        **`stalled-cross-milestone <repo>#m`**; report it with the repair advice
        `fix the edge: re-run /kp-sync-spec-tasks (it pulls the blocker forward into the dependent's milestone), or edit the marker to point at the same-or-earlier-milestone item the dependent actually needs`, **→ notify**, and stop. Landing the blocker early is not the fix.
      - Otherwise → outcome **`blocked-on-dependency <repo>#m`**; report,
        **→ notify** (the operator must land the blocker first), and stop.

      Never build on an unmerged dependency.
   4. **The §1.3 check finds a decision** → outcome **`blocked-on-decision #d`**;
      report and stop (filing the decision pinged the operator; a creator-decided one is
      pinged by `kp-do-gh-ready-items` §1.8 only if its resolve fails). Never launch a
      child into a known impasse.
   5. **An earlier milestone still has open work.** Milestones run strictly in order
      (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Milestone sequencing*): run
      `~/.claude/skills/kp-gh-lib/scripts/milestone-gate.sh --project <owner>/<number> <R>
      <n>`, with the run's resolved project. With `waitingOn`
      set, apply `~/.claude/skills/kp-gh-lib/NOTES.md` § *Milestone sequencing* →
      *Audit gate* first: its round cap (outcome **`waiting-on-audit-close #d`**), or, on
      `auditNeeded`, one audit round (a `kp-audit-alignment` child, then the gate read
      again — outcome **`audit-failed M<k>`**, `capacity-limit`, or on to step 6 once
      the gate opens), or `audit: no spec repo` when §0 resolves none. Still
      `waitingOn` → outcome **`waiting-on-milestone M<k>`**; report it with the
      `openEarlier` items and stop, **without** a notify — waiting needs no operator
      action. On `--dry-run`, report the audit round or decision it would run and
      launch nothing. A non-zero exit →
      outcome **`milestone-gate-failed`** with the script's stderr; stop, never launching
      past a gate that could not decide. Whatever the outcome, name every `crossEdges`
      entry in the report: an earlier-milestone item blocked by a later-milestone one
      stalls both milestones until the edge is removed.
   6. **§1.2 found an open or merged PR** → skip the build, go to **§3** with it —
      whatever the Status (after a denial the item sits In progress while its PR is
      open). A merged, draft or otherwise unadvanceable PR is `pr-loop.sh`'s to
      handle, not this skill's.
   7. **Otherwise** — Backlog, Ready, Blocked, In progress, In review, or Done alike —
      **§2 build**. `kp-do-gh-task` resumes an existing worktree/branch idempotently.
5. **On `--dry-run`, stop here** and print the plan.

## Child sessions

For each child the log `<log>` is `<scratchpad>/task-loop-<repo-name>-<n>-<phase>.log`
(`<phase>` is `build`; the PR phase launches no child of this skill — `pr-loop.sh`
launches its own and names their logs, §3), in the session scratchpad dir; write it out as a
literal path in every call, since a shell variable set in one `Bash` call is gone in the
next. Every child runs from this checkout, launched and waited on with
`~/.claude/skills/kp-gh-lib/scripts/run-child.sh` exactly as the `run-child.sh` section of `kp-gh-lib/SKILL.md` says —
one launch call, then foreground `--wait` calls (`Bash` `timeout: 540000`) re-issued
until the child's result line replaces `status: running`:

```bash
~/.claude/skills/kp-gh-lib/scripts/run-child.sh --log "<log>" --cwd "$PWD" --model M \
  -- "<the child's prompt>"
~/.claude/skills/kp-gh-lib/scripts/run-child.sh --wait "<log>"
```

The script owns the detached launch, the family's standard flag set (`bypassPermissions`
among them — a child does git / `gh` / worktree / push writes with no human present), the
exit sentinel and the capacity grep. **Never end the turn while a child is still
running** — nor while a `pr-loop.sh --wait` (§3) last printed `status: running` — and
never reach for `run_in_background` or `Monitor`
(`~/.claude/skills/kp-gh-lib/NOTES.md` § *Waiting in a headless session*).

**Capacity check — before any GitHub read.** A child started after the Claude usage limit
is hit prints one line and exits without touching GitHub, which the state reads below
would misread as a failed build or a parked PR. The check is per phase:

- **Build:** the `capacity=` field of the build child's `run-child.sh --wait`; a hit is
  anything but `none`.
- **PR loop:** `pr-loop.sh --wait` exit `5`, which covers a limit any of its review, fix
  or escalate children hit; its `reset=` field carries the reset time and its `limit:`
  line, quoted in §4, the child's limit line.

On a hit the outcome is **`capacity-limit`**: no board move, no decision issue, no
further child, the item and its PR left exactly as the child left them. Go to §4, whose
wrap-up names the hit with the `reset=` time; send nothing else for it. Never retry or wait in a loop — a re-run after the reset resumes from
GitHub state.

A **non-zero child exit code is recorded but is not itself the outcome** — GitHub state
is.

## 2. Build

Launch `kp-do-gh-task` as a child (see "Child sessions") with the prompt
`/kp-do-gh-task <n> --project <project>`, at model `M`.

After the wait and the capacity check, **detect the build outcome
from GitHub state, not the log** — re-run the §1.2 lookup
(`~/.claude/skills/kp-gh-lib/scripts/find-task-pr.sh <R> <n>`) and read the item's
Status with `~/.claude/skills/kp-gh-lib/scripts/item-id.sh <R> <n> <project-id>`:

- **An open PR exists** → go to **§3** with it. Note it in the report if the Status is
  not `In review` (a board write that did not land) — the PR, not the board, is what
  `pr-loop.sh` drives.
- **No PR + the §1.3 check finds a decision** (the clarity gate, `kp-do-gh-task` §1.4)
  → outcome **`blocked-on-decision #d`**, stop (filing it pinged the operator; a
  creator-decided one is pinged by `kp-do-gh-ready-items` §1.8 only if its resolve
  fails).
- **No PR otherwise** (build or push failed) → outcome **`build-failed`** with the
  `<log>` path, **→ notify**, stop.

## 3. PR loop

Run the PR's review ⇄ fix loop with `~/.claude/skills/kp-gh-lib/scripts/pr-loop.sh`
directly, from this checkout — no child session of this skill. The script launches the
review, fix and escalate children itself, at model `M`, reads every outcome from GitHub,
applies the stop policy in `kp-do-gh-pr-loop/SKILL.md` § *Loop policy*, and does the
close-out. This skill never launches a `kp-review-gh-pr` or `kp-fix-pr` session
directly.

1. **Start — one call:**
   ```bash
   ~/.claude/skills/kp-gh-lib/scripts/pr-loop.sh start <R> <pr> --project <owner>/<number> \
     --model M [--max-cycles <k>]
   ```
   `--max-cycles <k>` only when §0.1 received it. By its exit:
   - **`3`** — `status: running state=<file>`: the first review child is running. Keep
     `<file>` as a literal path and go to step 2.
   - **`0`** — the PR was already merged and the close-out ran → outcome **`merged`**,
     with no `item-outcome.sh` read. Record the item's state (`gh issue view <n> -R <R>
     --json state`) so the report shows the close-out landed.
   - **`4`** — the PR is closed or a draft, nothing launched → the outcome is the
     `outcome=` value it printed (**`pr-closed`** or **`pr-draft`**), with no
     `item-outcome.sh` read.
   - **`1`** or **`2`** — a failed lookup or a bad argument → outcome
     **`pr-loop-failed`** with its stderr, **→ notify**, stop.
2. **Wait.** Re-issue, as a foreground `Bash` call with `timeout: 540000`, with
   `<file>` written out literally:
   ```bash
   ~/.claude/skills/kp-gh-lib/scripts/pr-loop.sh --wait "<file>"
   ```
   while it prints `status: running state=<file>` (exit `3`) — see "Child sessions":
   never end the turn while it does. Any other exit ends the loop, which has printed its
   cycle table, a `close-out:` line (on a merge), a `logs:` line naming every child's
   log, and one terminal line `outcome=<o> [reason='<r>'] [reset='<t>'] state=<file>`.
   By its exit:
   - **`0`** merged, or **`4`** parked → step 3.
   - **`5`** — the capacity hit for this phase: outcome **`capacity-limit`** exactly as
     the "Capacity check" paragraph describes, with the reset time taken from `reset=`.
   - **`1`** — a lookup or launch failed; the state file is unchanged. Re-issue `--wait`
     once; a second exit `1` → outcome **`pr-loop-failed`** with its stderr,
     **→ notify**, stop.
   - **`2`** — a bad argument → outcome **`pr-loop-failed`** with its stderr,
     **→ notify**, stop.
3. **Detect the outcome from GitHub state** after a `--wait` exit `0` or `4`: run
   `~/.claude/skills/kp-gh-lib/scripts/item-outcome.sh <R> --pr <pr>`
   (`kp-gh-lib/SKILL.md` § *`item-outcome.sh`*) and map its `outcome=`:
   - `merged` → **`merged`**. Also record the item's state (`gh issue view <n> -R <R>
     --json state`) so the report shows the close-out landed.
   - `blocked-on-decision` → **`blocked-on-decision #<decision>`**.
   - `parked` → **`parked`**; record its `mergeStateStatus` and the `logs:` line
     `pr-loop.sh` printed.
   - `pr-closed` → **`pr-closed`**.
   - A non-zero exit → **`outcome-read-failed`**, with the script's stderr.

None of the step 3 outcomes, nor `pr-draft`, notifies: a park files — or reuses — a
human-gated item through the script's escalate child, and filing it pings the operator.
Only `pr-loop-failed` does.

Each child posts its own token-usage comment (the family convention); this skill
**does not** duplicate per-child reporting.

## 4. Report

**First release the item lock** when §0.4 took it (so never on `--dry-run`,
`already-running` or `lock-failed`):
`~/.claude/skills/kp-gh-lib/scripts/run-lock.sh release --workspace <workspace> <repo-name>-<n>`.
A non-zero exit (`1` or `3`) is noted once in the report and never changes the run's
outcome.

Print: the item (`<R>#<n>`, title), the resolved project and model (and "no model
label" when defaulted), the §1.4 entry decision, the phases run — the build child's exit
code and `<log>` path; for the PR phase, the cycle table, the `close-out:` line and the
`logs:` line `pr-loop.sh` printed — the PR (or "none"), and the terminal outcome ∈ `{merged,
blocked-on-decision #d, blocked-on-dependency <repo>#m, stalled-cross-milestone <repo>#m,
waiting-on-milestone M<k>,
waiting-on-audit-close #d, audit-failed M<k>, audit: no spec repo,
milestone-gate-failed, build-failed, parked, pr-closed, pr-draft, pr-loop-failed,
closed-unmerged, not-coding,
outcome-read-failed, skipped: needs-contract, capacity-limit, already-running,
lock-failed}`, plus every `crossEdges` entry §1.4 named, and a §0.4 `takeover=` line
when there was one. On
`capacity-limit`, **quote the child's limit line verbatim** (in the PR phase, the
`limit:` line `pr-loop.sh` printed) — a parent
`kp-do-gh-ready-items` reads it through the `capacity=` field `run-child.sh` reports. Note a failed notify send, if any.

**Then send the session wrap-up** — except on `already-running` and `lock-failed` —
with `send.sh --session-end` (see "Operator notifications") — one line with the item and its terminal outcome, plus the reset time
on `capacity-limit`. E.g. `shop-app #42 "Add wishlist page": merged via PR #88.` or
`shop-app #42: Claude usage limit hit in the build, resets 2:30am (Europe/Berlin) — re-run /kp-do-gh-task-loop 42 after.`
A failed send is noted once and never fails the run.

## Invariants

- **Owns no build, review, or loop logic.** Every code change, verdict, merge, board
  transition, PR comment, decision issue, and token report is performed by a child
  session — the `kp-do-gh-task` build this skill launches, or the `kp-review-gh-pr` /
  `kp-fix-pr` / escalate children `pr-loop.sh` launches; this skill only reads GitHub
  state, launches the build, runs `pr-loop.sh`, notifies, and reports. It never launches
  a review or fix session itself.
  The one exception is the milestone audit gate (§1.4 step 5): it launches a
  `kp-audit-alignment` child and, after six rounds, files the single audit-close
  decision itself, per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Milestone sequencing* →
  *Audit gate*.
- **Any Status is a valid start; GitHub state decides the phase.** The §1.4 entry
  decision reads the issue, its PR, its blockers, open decision issues and the milestone
  gate — never the
  board column — so a re-run from wherever the item stopped resumes the right phase.
- **Fresh context per phase, and the turn always blocks on it.** Each build is a
  separate headless session launched by
  `~/.claude/skills/kp-gh-lib/scripts/run-child.sh`, and each review, fix and escalate
  phase one launched by `pr-loop.sh`, at the item's `model:*` tier (default `opus`,
  overridable with `--model`); both are waited on with foreground `--wait` calls — never
  `run_in_background`, never `Monitor`.
- **Dependencies, decisions and milestone order are law.** An open `blocked-by:`
  blocker, an open decision issue blocking the item, or an earlier milestone with open
  work stops the run before any build child is launched; only the milestone wait goes
  unnotified. An earlier milestone is done only once audited — no seventh audit round
  ever runs for it.
- **No launch without a contract.** An item labelled `needs-contract` launches no child
  and is reported as `skipped: needs-contract`.
- **One live run per item**, held by the §0.4 lock and released in §4.
- **Bounded fix loop — delegated.** When the review ⇄ fix loop stops is the policy in
  `kp-do-gh-pr-loop/SKILL.md` § *Loop policy*, which `pr-loop.sh` carries out; this
  skill never re-implements or overrides it, and only passes `--max-cycles <k>`.
- **Outcome from GitHub state, not logs, not child exit codes.** The one log read is
  the build's capacity check, which runs before any state read; `pr-loop.sh`'s own exit
  codes only route §3 (running, capacity, a failed run, a PR closed or draft on entry).
- **A capacity hit is not a failure.** `capacity-limit` means no board move, no
  decision issue, no further child, and no message beyond the wrap-up — never a retry or
  wait loop.
- **Pings only when the operator is needed or the session ends.** Build-side stops no
  filed issue announced notify (§1–§2), as does `pr-loop-failed` (§3); a blocking
  decision, a merge and every other PR outcome never do; the §4 wrap-up is sent only when this run is top-level; a failed send never
  aborts the run.
- **Idempotent/resumable through the children.** Re-running re-evaluates §1.4 from
  current GitHub state; the children's check-before-create idempotency (existing
  worktree/branch/PR, single review, no re-merge) means a re-run resumes rather than
  duplicating work.
