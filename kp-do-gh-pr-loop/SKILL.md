---
name: kp-do-gh-pr-loop
description: Drive one GitHub PR to merged, unattended — loop kp-review-gh-pr ⇄ kp-fix-pr, each in a fresh headless subagent session, until the reviewer approves + squash-merges. On merge, verify the linked work item is closed and its board item reached Done, closing them explicitly if the Closes-keyword automation did not fire, and move the item's fully unblocked dependents from Blocked to Ready. A cycle makes progress only when its denial lists strictly fewer blockers, majors and CI findings than the previous denial (minors and nits never count; a head advance alone is a stall), and cycles are capped at 6 by default; when two consecutive cycles stall — or the cycle cap is reached, a finding can't be actioned, the merge is blocked, or the child raises a clarity gate — it stops, raises a prioritised, assigned blocking human-decision issue (kp-do-gh-task §1.4 pattern) (filing it pings the operator on Telegram) and leaves the PR open; a wrap-up ping only when top-level. Owns no build logic. Manual-only.
disable-model-invocation: true
argument-hint: [pr-number] [--project <number|owner/number|id>] [--model <tier>] [--stall-limit <k>] [--max-cycles <k>] [--dry-run]
allowed-tools: Read, Grep, Glob, Bash
model: sonnet
---

# Drive one PR to merged

Orchestrator for a **single PR**. Two per-PR skills own the lifecycle —
`kp-review-gh-pr` (review → approve + squash-merge → **Done**, or `REQUEST_CHANGES`
→ back to **In progress**) and `kp-fix-pr` (address a denial → push → **In review**).
This skill runs them **in a loop until the PR is merged**, closes out the linked work
item, and escalates to a human the moment the loop stops converging.

It **composes** those skills and **owns no implementation or review logic of its
own.** Every code change, verdict, board transition, PR comment, and token report is
made by a child skill in its own **fresh headless `claude -p` session**. The loop
itself — launching each child, waiting on it, reading GitHub state to decide the next
step, the close-out — is `~/.claude/skills/kp-gh-lib/scripts/pr-loop.sh`, so this skill
spends a handful of turns per PR, not one per launch, wait and read. Because each child
runs in a genuinely fresh context, the PR is processed exactly as if the operator had
typed each `/kp-…` command by hand, one after another.
`kp-do-gh-task-loop` calls `pr-loop.sh` directly, so this skill is the entry point for
running the loop on a PR by hand, for `kp-do-gh-pr-loop-all` and for
`kp-resolve-spec-decision`.

Runs **inline (no fork)** like its siblings: it is itself a headless child of
`kp-do-gh-pr-loop-all` and `kp-resolve-spec-decision`, which grep
its log for the CLI's usage-limit line, and a fork has not been probed to print that
line. The children do the isolated,
long-running work in their own detached sessions, which `pr-loop.sh` blocks on one at a
time (§2) — this skill never lets a turn end while one is still running.

**Goal (success criteria):** the PR reaches a terminal outcome — **merged** (linked
issue closed, board item Done), or **parked with a blocking human-decision issue
raised, the operator notified, and the PR left open** — or **stopped on a Claude usage
limit** (`capacity-limit`, §2), the PR left exactly as the child found it and the
operator notified with the reset time.

## Loop policy — fewer findings, bounded cycles

`pr-loop.sh` implements this policy; it is stated here so the operator can read what
the loop will do. The loop runs **while it is converging** and stops when it isn't, or
when it reaches the cycle ceiling. After each review⇄fix cycle, it reads from GitHub
state:

- **`count`** — the denial's merge-blocking findings, from `denial.bySeverity` of
  `pr-verdict-state.sh`: `blockers + major + ci`, the top-level bullets
  (lines starting `- `; indented continuation lines belong to the bullet above) under
  those groups of the latest denied verdict's `### Findings (for the build agent)`
  section alone — never the human TL;DR. A `null` `major` counts as 0: the script leaves
  a group null only when the denial has no heading for it, and the reviewer leaves out a
  group with no findings. Minor findings and nits never count — `kp-fix-pr` still fixes
  them, but a fresh reviewer adding new nits must not stall a loop whose real problems
  are shrinking. **Fallback:** an old denial whose `bySeverity.combined` is non-null
  (one `**Major / Minor / Nits**` group) cannot be split, so its `count` is the old
  total, `denial.count`.
- **`minor+nits`** — `(minor or 0) + (nits or 0)` from the same `bySeverity`, or `—`
  under the fallback. Reported in the cycle table (§5) only; it never decides progress.
- **`findings`** — `denial.fingerprint`, that same section with its whitespace
  normalised and hashed (sha256). Reported in the cycle table (§5) only; it never
  decides progress.
- **`head`** — the PR head commit: `gh pr view <pr> --json headRefOid --jq .headRefOid`.
  Reported only.

A cycle **made progress** only when its denial's `count` — blockers, majors and CI —
is **strictly fewer** than the previous denial's. Anything else is a **stall** — an equal or higher count, and
**a head advance alone**: every fix pushes a commit, so a moving head proves nothing.
When there is no previous denial, the cycle sets the baseline and counts as progress.
**`stall-limit`** consecutive stalls (default **2**, `--stall-limit`) ends the loop and
escalates (§2). **Effort boost:** after the first stalled fix cycle the loop continues
past, the remaining review and fix children run at `xhigh` (or `max` when the item's
tier is already `xhigh` or `max`), even after a later cycle makes progress; the escalate
child keeps the tier's effort. A cycle in which no verdict appeared at all (CI never
settled) counts as a stall but never boosts. A child that exited on the Claude usage limit counts as neither — it ends
the loop (§2, capacity check).

`--max-cycles <k>` is a hard ceiling, default **6**: reaching it escalates the same
way, even while findings are still falling. `--max-cycles 0` disables the ceiling,
leaving the loop bounded by progress alone.

## Operator notifications (kp-msg-me)

Per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Operator notifications*: the decision issue
a park raises pings the operator itself — `create-item.sh` sends that message when the
escalate child files it — so the loop sends **no per-event message**. Its one message is
the §5 session wrap-up, sent with `--session-end` so it reaches the operator only when
this run is the session they launched; as a headless child (of
`kp-do-gh-pr-loop-all` or `kp-resolve-spec-decision`) the script drops it:

```bash
~/.claude/skills/kp-msg-me/scripts/send.sh --session-end "<one-line message>"
```

A merge, a closed or draft PR and ordinary cycle progress never send anything else; a
failed send (e.g. exit `3` = credentials unset) is noted once in the report and
**never** aborts the run.

## 0. Setup

1. **This run's arguments: `$ARGUMENTS` (empty if none). Parse them.** The first bare token is the **PR number** (required; if
   missing, stop and ask for one). Then:
   - `--project <number|owner/number|id>` — the GitHub Project (v2).
   - `--model <tier>` — model tier for every child session: a model alias that may
     carry an effort (`opus`, `opus-xhigh`), passed on unchanged to `pr-loop.sh`, which
     splits it; default is the linked issue's **`model:*`** label value, else **`opus`**
     (family rubric).
   - `--stall-limit <k>` — consecutive stalls that end the loop (default **2**).
   - `--max-cycles <k>` — hard ceiling on cycles (default **6**; `0` disables it).
   - `--dry-run` — print the resolved plan (PR, linked issue, model, project,
     current verdict state, what the first cycle would run) and execute nothing.
2. **Primary-checkout guard.** §0.3's preamble guards the repo and auth; this skill
   additionally refuses to run **inside a child worktree**:
   `~/.claude/skills/kp-gh-lib/scripts/ensure-checkout.sh --here --no-fetch` (§0.3
   fetches). Exit `5` → stop and tell the operator to run from the PR's primary
   checkout, where the children create their `../<repo-name>-*-pr-<n>` siblings.
3. **Preamble — one call.** `~/.claude/skills/kp-gh-lib/scripts/preamble.sh --pr <n>
   [--project <…>]`, then do what `kp-gh-lib/SKILL.md` § *`preamble.sh`* says with its
   JSON, its exit code, and any `null` board field.

   `<R>` is `.repo` — every `gh` read below is `-R <R>`, so a bare PR/issue number
   never crosses repos. Keep `.project.owner`, `.project.number`, `.project.id`,
   `.itemId`, `.status.fieldId`, the **`In progress`**, **`In review`**, **`Blocked`**,
   **`Ready`** and **`Done`** ids from `.status.options`, and `.priority.top`. A non-zero
   exit stops the run here, before §1 launches anything. **Every child run is passed
   `--project <owner>/<number>`** so no child ever stops to ask — that is what makes
   them unattended; each child still runs its own preamble, since `--project` carries no
   field or option ids.

## 1. Start the loop

From this checkout, one call with §0.1's arguments (`--project` as
`<.project.owner>/<.project.number>`; the optional flags only when given):

```bash
~/.claude/skills/kp-gh-lib/scripts/pr-loop.sh start <R> <pr> --project <owner>/<number> \
  [--model <tier>] [--stall-limit <k>] [--max-cycles <k>] [--dry-run]
```

It reads the PR and its linked work item — the `Closes` / `Fixes` / `Resolves` issue,
else the `task/<n>-<slug>` branch's; its **`model:*`** label is the default `--model`,
else **`opus`**; a linked item that is already **`CLOSED`** and labelled
**`type:research`** (a research PR from `kp-resolve-spec-research`, whose resolver closes
the item itself) is **reference-only** and handled as no linked item, so the loop never
reopens, closes, moves or comments on it; no linked item at all is not an error. Then,
by its exit:

- **`--dry-run`, exit 0** — it printed the plan (PR, linked issue, model, project,
  current verdict state, first phase) and wrote nothing. Print it and stop.
- **Exit 0** — the PR was already **`MERGED`**: it ran only the close-out (§2) and wrote
  no state file. Go to §5.
- **Exit 4** — the PR is **`CLOSED`** (a human's decision, not a defect to fix) or a
  **draft** (nothing to review yet): `outcome=pr-closed` / `outcome=pr-draft`, nothing
  launched. Go to §5.
- **Exit 3** — `status: running state=<file>`: the first review child is running. Keep
  `<file>` for §2.
- **Exit 1 or 2** — a failed lookup or a bad argument. Stop and report its stderr.

## 2. Wait for the loop

Re-issue, in **foreground** `Bash` calls (`timeout: 540000`, just under the 10-min cap),
with `<file>` written out as a literal path — a shell variable set in one `Bash` call is
gone in the next:

```bash
~/.claude/skills/kp-gh-lib/scripts/pr-loop.sh --wait "<file>"
```

Each call returns within 8 minutes. `status: running state=<file>` (exit 3) means call it
again; anything else is the end of the loop: the cycle table, the close-out result, the
child log paths, and one terminal line `outcome=<o> [reason='<r>'] [reset='<t>']
state=<file>`. **Never end the turn while it says running**, and never reach for
`run_in_background` or `Monitor`: both are dropped the moment a headless turn ends.

Between calls the script runs the loop the Loop policy describes, one fresh headless
child per phase, every outcome read from GitHub state, never from a child's stdout:

1. **Review** — `/kp-review-gh-pr <pr> --project <project>`. The verdict comes from the
   PR's formal reviews and the marked verdict comments (`pr-verdict-state.sh`); a denial
   counts only when no `kp-fix-pr` summary is newer than it. **Merged** → the close-out
   below. **Approved but not merged** → escalate `merge-blocked (<mergeStateStatus>)`.
   **No verdict** (CI still pending past the reviewer's own timeout) → a stall and a
   cycle; `stall-limit` of them escalates `ci-not-settling`. Otherwise the script then
   waits for pending checks to finish (at most 60 minutes, polling every minute, no
   child running) before the next review; checks still pending at 60 minutes escalate
   `ci-not-settling`.
2. **Fix** — `/kp-fix-pr <pr> --project <project>`, then the cycle is scored by the Loop
   policy: progress, or a stall (`stall-limit` of them escalates `stalled (<k> cycles,
   findings not reduced)`). After the first stalled fix cycle the loop continues past,
   the remaining review and fix children run at `xhigh` (or `max` when the item's tier is
   already `xhigh` or `max`); that cycle's row reads `stall → effort <level>` and the
   report prints `boost: <level>`.
3. **Escalate at once** when the latest fix summary names a finding deliberately not
   actioned (`unactionable-finding`), an open `type:decision` / `type:question` /
   `type:conflict` issue `blocks:` this PR, its item or its `spec-ref` (a child hit its
   clarity gate: `blocked-on-decision #d`, reused, never duplicated), the PR turned
   `CLOSED` or draft mid-loop (`pr-closed` / `pr-draft`), or `max-cycles` is reached.
4. **Escalation** is one headless `/kp-do-gh-pr-loop-escalate <pr> --project <project>
   --evidence <file>` child, handed the reason, cycles, stalls, last findings,
   `mergeStateStatus`, the declined finding and every log path. It raises — or reuses —
   the prioritised, assigned blocking issue (a raised one through
   `~/.claude/skills/kp-gh-lib/scripts/create-item.sh`), comments on the PR and the item, moves the
   item to **Blocked** (a newly filed issue pings the operator through `create-item.sh`);
   the script reads the item back
   by its `blocks: <R>#<pr>` marker. The child checks the decision's edge onto the
   linked item with `~/.claude/skills/kp-gh-lib/scripts/edge-check.sh` before leaving it.
5. **Capacity check — after every child, before any GitHub read.** A child that hit the
   Claude usage limit exits without touching GitHub, so it is neither a missing verdict
   nor a stalled fix: `capacity-limit`, no stall or cycle counted, no escalation, no
   board move, the PR left exactly as the child left it. Never retry or wait in a loop
   — a re-run after the reset resumes from GitHub state.
6. **Close-out on merge.** `kp-review-gh-pr` merges with `--squash --delete-branch`.
   The `Closes #N` keyword closes the issue only on a default-branch merge; a milestone
   item's PR merges into `release/M<k>` (`~/.claude/skills/kp-gh-lib/NOTES.md`
   § *Milestone branch*), and the close-out closes it otherwise. It closes a
   still-`OPEN`, non-reference-only linked issue (`--reason completed`, "Closed by merged
   PR #<pr> (<sha>)."), sets its board item to **Done**, and moves the merged work's
   fully unblocked dependents from **Blocked** to **Ready** with
   `unblock-dependents.sh` — on the linked issue, or on the PR itself when there is no
   linked item or only a reference-only one. It also deletes the merged PR's local branch
   in the primary checkout with `branch-cleanup.sh`, removing a clean worktree on it first
   and leaving a dirty one. Each part is best-effort and noted; re-running it converges.

By the terminal line's exit:

| exit | outcome | next |
|---|---|---|
| 0 | `merged` — close-out done | §5 |
| 4 | parked: `blocked-on-decision`, `merge-blocked`, `unactionable-finding`, `ci-not-settling`, `stalled`, `max-cycles`, `pr-closed`, `pr-draft` — the reason names the decision issue | §5 (a decision the escalate child filed already pinged) |
| 5 | `capacity-limit` — `reset=` carries the reset time, and a `limit:` line quotes the child's | §5, whose wrap-up names the hit |
| 1 | a GitHub lookup or launch failed; the state file is unchanged, so re-running `--wait` retries | report the stderr |

A `--wait` on a finished loop reprints its result. Each child posts its own token-usage
comment (the family convention); this orchestrator **does not** duplicate per-child
reporting.

## 5. Report

Print: the PR and its linked issue (or "none"), the resolved project and model, the
**cycle table** `pr-loop.sh` printed — cycle | phase outcome | `head` before→after | `count` | `minor+nits`
(report-only) | findings fingerprint changed? | progress/stall — the terminal outcome ∈ `{merged, blocked-on-decision #d,
merge-blocked, unactionable-finding, ci-not-settling, stalled, max-cycles,
pr-closed, pr-draft, capacity-limit}` (on `capacity-limit`, quote the child's limit line
verbatim from the `limit:` line — a parent `kp-do-gh-pr-loop-all` greps this output for it), for a decision
issue the escalate child created its report line from NOTES § *Every new item has a milestone*, the close-out result (issue state, board status, and the dependents promoted / skipped, or why that step was skipped or failed), and the
**log paths** for every child session so the operator can pick up where the
loop left off.

**Then send the session wrap-up** with `send.sh --session-end` (see "Operator
notifications") — one line with the terminal outcome, whatever it is: when the operator
launched this run, this is the message that it finished; as a headless child it is
dropped, and the parent reports the outcome instead. E.g. `shop-app PR #88 (#42) merged
after 2 cycles — issue closed, board Done.` A failed send is noted once and never fails
the run. On `capacity-limit` the wrap-up carries the reset time — e.g.
`shop-app PR #88 (#42): Claude usage limit hit in cycle 2, resets 2:30am (Europe/Berlin) — PR left open, re-run /kp-do-gh-pr-loop 88 after.`

## Invariants

- **Owns no review or build logic.** Every verdict, code change, board transition,
  PR comment, and token report is performed by a child `kp-review-gh-pr` / `kp-fix-pr`
  session; `pr-loop.sh` only launches children, reads GitHub state and completes the
  close-out, and the decision issue is raised by its `kp-do-gh-pr-loop-escalate` child.
- **Fresh context per phase, and the turn always blocks on it.** Each review and each
  fix is a separate headless session `pr-loop.sh` launches — never a reused context,
  always at the linked item's `model:*` tier (default `opus`, overridable with
  `--model`); fix and escalate run at the tier's effort, and the review at `high` when
  that effort is `low` or `medium` (a tier with no effort passes none), until the
  first stalled fix cycle boosts review and fix (Loop policy) — and this skill waits on the loop with **foreground `pr-loop.sh --wait`
  calls**, never `run_in_background` and never `Monitor` (§2).
- **Outcome from GitHub state, not logs.** Merge, denial, progress, and stall are read
  from `gh pr view` / issue state / board status plus the marker-tagged comments
  (`kp-review-gh-pr:verdict`, `kp-fix-pr:summary` — the only denial channel on a
  self-authored PR), never parsed from child stdout. The one log read is the capacity
  grep, before any of them.
- **A capacity hit is not a stall.** A child that exits on the Claude usage limit is
  `capacity-limit`: no stall or cycle counted, no decision issue, no board move, the PR
  left as the child found it, the loop ended, and exactly one message (the §5 wrap-up,
  with the reset time) sent — never a retry or wait loop.
- **The loop is bounded by falling findings and by a cycle ceiling.** A cycle makes
  progress only when its denial lists strictly fewer blockers, majors and CI findings
  than the previous denial — minors and nits never count, and a head advance alone is
  a stall; `stall-limit` (default 2) consecutive
  stalls end it. `--max-cycles` (default 6; `0` disables it) caps it regardless.
- **Never reads human-only content into context** — the `<!-- human-only -->` fence
  and the reviewer's `### TL;DR (for humans)` section are skipped everywhere,
  including in the findings fingerprint.
- **A human impasse always produces a real, findable artifact** — a prioritised,
  assigned, board-linked `type:decision` / `type:conflict` / `type:question` issue that
  `blocks:` the PR and its item, deduped on that `blocks:` marker with
  `~/.claude/skills/kp-gh-lib/scripts/find-marker.sh` so re-runs reuse it rather than stacking
  duplicates; filing it pings the operator on Telegram (`create-item.sh`). It never
  resolves the impasse itself.
- **Never merges, force-merges, closes, or edits repo code itself.** The merge is the
  reviewer's act; the loop's only writes are the decision issue and its linking
  comments (the escalate child), the close-out (`gh issue close`, board Status,
  dependents Blocked→Ready), and the notification.
- **Leaves the evidence in place on a park** — the PR stays open, child worktrees stay,
  log paths and the state file are reported.
- **Idempotent/resumable.** Re-running on a `MERGED` PR only completes the close-out,
  and moves no dependent twice (one already in `Ready` is no longer `Blocked`);
  re-running on a parked PR reuses the existing decision issue and continues the loop
  from current GitHub state; the children's own idempotency (single review, no
  re-merge, no duplicate fix commit, verdict and summary comments `PATCH`ed only on a
  true re-run) means a re-run resumes rather
  than duplicating work.
