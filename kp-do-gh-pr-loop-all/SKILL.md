---
name: kp-do-gh-pr-loop-all
description: Drive every open PR in one repo to merged, unattended — walk the repo's open non-draft PRs in ascending numerical order and run kp-do-gh-pr-loop on each in a fresh headless session, one at a time, so every PR gets the full review ⇄ fix loop, merge, and work-item close-out. A PR that parks (stall, merge-blocked, unactionable finding, decision issue, CI not settling) is left open and the pass continues to the next PR; drafts and PRs that another child already merged or closed are skipped. Owns no review, build, or escalation logic — the per-PR loop owns all of it. Manual-only.
disable-model-invocation: true
argument-hint: <owner/name|repo-name> [--project <number|owner/number|id>] [--model <alias>] [--only <#,#,…>] [--skip <#,#,…>] [--from <#>] [--limit <k>] [--stall-limit <k>] [--max-cycles <k>] [--include-drafts] [--dry-run]
allowed-tools: Read, Grep, Glob, Bash
model: sonnet
---

# Drive every open PR in a repo to merged

Repo-scoped sibling of `kp-do-gh-pr-loop` (one PR) and `kp-do-gh-ready-items` (the
whole cross-repo board). This skill takes **one repo** and walks **all of its open
PRs in ascending numerical order**, handing each in turn to `kp-do-gh-pr-loop`, which
owns the entire per-PR lifecycle: the `kp-review-gh-pr` ⇄ `kp-fix-pr` loop, the
squash-merge, the linked-item close-out, and the escalation when the loop stops
converging.

It **composes** that skill and **owns no review, build, merge, or escalation logic of
its own.** Every verdict, code change, board transition, PR comment, decision issue,
and token report is made by a child in its own **fresh headless `claude -p` session**
— this skill only orders PRs, launches one child per PR, and reads GitHub state to
record the outcome. Because each child runs in a genuinely fresh context, the repo is
processed exactly as if the operator had typed `/kp-do-gh-pr-loop <n>` by hand for
each PR, oldest first.

Runs **inline (no fork)** like its siblings: §2 launches each child with
`run-child.sh` and waits on it in foreground `--wait` calls, and the capacity hit is read
from the `capacity=` field `run-child.sh` reports over the child's log, which quotes the
CLI's usage-limit line — a line a fork has not been probed to print.

**Ascending numerical order is the point.** The lowest-numbered open PR is the oldest
and is the one others were most likely branched behind, so merging it first is the
order least likely to strand the rest on conflicts. This skill does **not** compute
dependencies between PRs — if the operator needs a different sequence, `--only` plus
repeated runs, or `kp-do-gh-ready-items` (which does sort by `blocked-by:`), is the
right tool.

**Goal (success criteria):** every selected open PR has been driven to a terminal
outcome by its own `kp-do-gh-pr-loop` run — **merged** (linked issue closed, board
item Done), or **parked** with a blocking decision issue raised and the PR left open, or
**stopped on a Claude usage limit** (`capacity-limit`, §2.3), which ends the pass —
processed **sequentially in ascending PR number**, each in a fresh headless session,
and a **final summary table** printed.

## Operator notifications (kp-msg-me)

Per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Operator notifications*. A decision issue a
child's park raises pings the operator when it is filed (`create-item.sh`), and each
`kp-do-gh-pr-loop` child's own wrap-up is dropped because it runs headless — so this
skill **sends no per-PR message**, and a merge never pings.

It sends exactly **one** message, the session wrap-up in §4, also when a pre-flight
failure (§0.2, §0.3) ends the pass before any child runs:

```bash
~/.claude/skills/kp-msg-me/scripts/send.sh --session-end "<one-line message>"
```

A failed send (e.g. exit `3` = credentials unset) is noted once in the report and
**never** aborts the pass.

## 0. Setup

1. **This run's arguments: `$ARGUMENTS` (empty if none). Parse them.** The first bare token is the **repo** (required; if missing,
   stop and ask for one). Accept `owner/name` or a bare `name` — a bare name resolves
   against the authenticated user first (`gh repo view <name>`), and if that misses,
   against the directory `<workspace>/<name>`'s `origin` remote; if it still can't be
   resolved unambiguously, stop and ask for the `owner/name` form. Record it as `<R>`;
   **every `gh` call below is repo-qualified with `-R <R>`** — a bare PR or issue
   number never crosses repos. Then:
   - `--project <number|owner/number|id>` — the GitHub Project (v2), passed through to
     every child.
   - `--model <alias>` — model override, passed through to every child. **Omit it by
     default**: each child resolves the model from its own PR's linked issue
     `model:*` label (default `opus`), which is per-PR correct where one flag here is
     not.
   - `--only <#,#,…>` — restrict the pass to these PR numbers.
   - `--skip <#,#,…>` — exclude these PR numbers.
   - `--from <#>` — start at this PR number (resume a pass that was interrupted);
     lower-numbered PRs are reported as `not-attempted`.
   - `--limit <k>` — process at most `k` PRs (applied **after** ordering, so the
     lowest-numbered survive the cap).
   - `--stall-limit <k>` / `--max-cycles <k>` — passed through to every child
     unchanged; see `kp-do-gh-pr-loop`'s loop policy for their meaning and defaults.
   - `--include-drafts` — also process draft PRs (off by default: `kp-do-gh-pr-loop`
     stops on a draft, so including them only produces parks).
   - `--dry-run` — print the resolved plan (repo, project, ordered PR list with title,
     author, draft/skip reason, linked item, model) and execute nothing.
2. **Launch guard.** `gh auth status` must succeed; else stop and go to §4, whose
   wrap-up names the failure.
   Resolve the repo's **local checkout** with one call,
   `~/.claude/skills/kp-gh-lib/scripts/ensure-checkout.sh <R> --workspace <workspace>
   --clone`, where the workspace root is the parent of the current checkout: it clones
   a missing checkout, requires a **primary checkout** whose `origin` is `<R>` (the
   children create `../<repo-name>-review-pr-<n>` / `../<repo-name>-fix-pr-<n>`
   worktree siblings there, and launching from inside a worktree would collide with
   them) and fetches it with `--prune`, so PR head refs and CI status reflect remote
   state. Its stdout is `<checkout>`. Any non-zero exit stops the pass and goes to §4
   the same way, the script's stderr naming the failure.
3. **Sync** — done by step 2's call.
4. **Resolve the Project (v2)**, same precedence as the family: `--project` → the
   checkout's `.claude/spec-sync.json` (`project`) → otherwise **ask** by listing
   candidates (`gh project list --owner <repo-owner>`, `gh project list --owner @me`)
   and stopping for a selection. Record the project's **owner login, number, and node
   id** (`gh project view <number> --owner <owner> --format json`). **The project is
   passed to every child run** (`--project <…>`) so no child ever stops to ask — that
   is what makes the pass unattended. This skill resolves the project **only to pass
   it on**; it reads and writes no board field itself.

## 1. Collect and order the PRs

1. **List the open PRs:**
   ```bash
   gh pr list -R <R> --state open --limit 200 \
     --json number,title,isDraft,author,headRefName,url,mergeStateStatus
   ```
   Raise `--limit` if the repo has more than 200 open PRs.
2. **Sort ascending by `number`** — numerically, never lexicographically (`#9` runs
   before `#10`).
3. **Apply filters** in order: `--only` (intersect), `--skip` (exclude), `--from`
   (drop lower numbers), drafts (excluded unless `--include-drafts`), `--limit` (cap).
   Every dropped PR keeps a recorded reason for the §4 table.
4. **Capture per PR:** number, title, author, head branch, and the **linked work item**
   — one `~/.claude/skills/kp-gh-lib/scripts/linked-item.sh <R> <pr>` call per PR. The
   linked item is its `.issue`; a spec PR is shown as its `.decisions`, comma-separated;
   note its `.via`
   for the run list. A non-zero exit records the PR's linked item as `unknown
   (linked-item.sh exit <code>)` and does not drop the PR. A PR with no linked
   item is **not** an error — `kp-do-gh-pr-loop` drives it to merge anyway; note it.
   Bot- and third-party-authored PRs are in scope by default; note the author so the
   §4 table shows who opened each one.
5. **Print the ordered run list** (number · title · author · linked item and its `via`
   · any skip reason). On **`--dry-run`, stop here** and emit the §4 summary with nothing
   executed.

## 2. Per-PR pipeline (sequential)

Process PRs **one at a time**, lowest number first. Never run two children
concurrently: they share the repo's remote, and a merge changes the base every later
PR is measured against.

For each PR `<pr>`, the child's log `<log>` is
`<scratchpad>/pr-loop-all-<repo-name>-<pr>.log` (session scratchpad dir), a fresh path per
PR so nothing is overwritten, and the `--log` / `--wait` argument of `run-child.sh`.
Write it out as a literal path in every call — a shell variable set in one `Bash` call
is gone in the next.

1. **Re-read the PR immediately before launching** — the list from §1 is a snapshot,
   and an earlier merge in this same pass may already have changed this PR:
   `gh pr view <pr> -R <R> --json state,isDraft,mergeStateStatus`.
   - **`MERGED`** → record `merged-earlier` (a previous merge closed it, e.g. a shared
     head or a squashed-in branch) and **skip the child**.
   - **`CLOSED`** → record `closed` and skip.
   - **Draft** (and no `--include-drafts`) → record `draft-skipped` and skip.
   - Otherwise → run it.
2. **Launch the per-PR loop** in a fresh headless session from the checkout, with
   `~/.claude/skills/kp-gh-lib/scripts/run-child.sh` exactly as the `run-child.sh`
   section of `kp-gh-lib/SKILL.md` says — one launch call, then foreground `--wait`
   calls (`Bash` `timeout: 540000`) re-issued while it prints `status: running`:
   ```bash
   ~/.claude/skills/kp-gh-lib/scripts/run-child.sh --log "<log>" --cwd <checkout> --timeout-min 600 \
     -- "/kp-do-gh-pr-loop <pr> --project <project>"
   ~/.claude/skills/kp-gh-lib/scripts/run-child.sh --wait "<log>"
   ```
   `--timeout-min 600` because one pr-loop covers several review ⇄ fix cycles, each
   with a CI wait. **Never end the turn while a child is still running**, and never
   reach for `run_in_background` or `Monitor`
   (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Waiting in a headless session*).
   Append `--model <alias>`, `--stall-limit <k>`, `--max-cycles <k>`
   inside the prompt only when the operator passed them (§0.1), never as `run-child.sh` flags —
   `--model` is the tier the pr-loop gives its own review and fix children; otherwise
   the child applies its own per-PR defaults. `run-child.sh` passes `bypassPermissions`,
   which is required: the run does git / `gh` / worktree / push writes with no human
   present.
3. **Capacity check, then detect the outcome.** After the child exits, and **before**
   classifying anything, read the `--wait` result line
   `exit=<code> capacity=<none|session-limit|weekly-limit> [reset='<text>'] log=<path>`:
   any `capacity=` other than `none` is a hit, and `reset=` (when present) is the reset
   time for the §4 wrap-up, else "reset time unknown". The limit can stop the child
   itself or one of its own children, whose limit line the child's report quotes
   (`kp-do-gh-pr-loop` §5). On a hit, record **`capacity-limit`** and **end the pass**: skip the classification
   below, leave the PR exactly as the child found it (no decision issue, no board move),
   record every remaining PR `not-attempted`, and go to §3 and §4. The limit is
   account-wide, so the next child would only hit it again; never retry or wait in a
   loop.

   Otherwise **detect the outcome from GitHub state, never from the child's stdout**:
   run `~/.claude/skills/kp-gh-lib/scripts/item-outcome.sh <R> --pr <pr>`
   (`kp-gh-lib/SKILL.md` § *`item-outcome.sh`*) and map its `outcome=`:
   - `merged` → `merged`. Also record the linked issue's state
     (`gh issue view <n> -R <R> --json state`) so the table shows the close-out landed.
   - `blocked-on-decision` → `blocked-on-decision #<decision>`.
   - `parked` → `parked` (the child escalated on merge-blocked, CI, or an unactionable
     finding without raising a new issue, or exited abnormally); record its
     `mergeStateStatus` and the `<log>` path.
   - `pr-closed` (closed unmerged mid-run) → `pr-closed`.
   - A non-zero exit → `outcome-read-failed`, with the script's stderr; the pass
     continues to the next PR.
   A **non-zero child exit code** (the result line's `exit=`) **is recorded but is not itself the outcome** — GitHub
   state is. A child that crashed after merging still counts as `merged`.
4. **Continue to the next PR regardless of the outcome** — except `capacity-limit`,
   which ends the pass (step 3). A park never ends the pass:
   the child already left the PR open, raised the decision issue, and pinged the
   operator, so the pass moves on. Do **not** re-run a parked PR in the same pass.
5. **Re-sync between PRs:** `git -C <checkout> fetch origin --prune` after each child,
   so the next PR's state reflects any merge that just landed.

## 3. Post-pass sweep

After the last PR, re-list the repo's open PRs (§1.1) once and note in the report any
PR that was **opened during the pass** (a number above the highest in the §1 list — a
child's fix run does not open PRs, but a concurrent human or bot may have). These are
**not** processed by this pass; list them as `arrived-during-pass` so the operator
knows a re-run will pick them up.

## 4. Final report

Print a table — **PR | title | author | linked item | outcome | log** — where
`outcome` ∈ `{merged, blocked-on-decision #d, parked, pr-closed, merged-earlier,
closed, draft-skipped, not-attempted, filtered-out, outcome-read-failed, capacity-limit}`.
Follow it with counts
(**merged / parked / skipped**), the list of decision issues raised across the pass
with their `/kp-resolve-spec-decision <n>` prompts, the `arrived-during-pass` PRs from
§3, and the scratchpad **log path** for every non-merged PR so the operator can pick up
where the loop left off. This skill makes **no board edits and posts no PR comments of
its own** — every transition and comment was made by a child.

**Then send the session wrap-up** (`send.sh --session-end`, per "Operator
notifications") — one line saying the pass is done. E.g.
`shop-app: PR pass done — 4 merged (#81 #83 #84 #86), 2 parked (#82 decision #91, #85 merge-blocked).`
Send this on every completed pass, including a `--dry-run` (say so) and a pass where
nothing was selected, and on a pre-flight failure (naming it); a failed send is noted
once and never aborts the pass.
On a `capacity-limit` pass (§2.3) the wrap-up is still the one message; it names the PR
that hit the limit and the reset time. E.g.
`shop-app: PR pass stopped — Claude usage limit on #85, resets 2:30am (Europe/Berlin); 2 merged, 3 not attempted.`

## Invariants

- **Owns no review, build, merge, or escalation logic.** Every verdict, code change,
  board transition, PR comment, decision issue, close-out, and token report is
  performed by a child `kp-do-gh-pr-loop` session (and, below it, `kp-review-gh-pr` /
  `kp-fix-pr`); this skill only orders PRs, launches children, and reads GitHub state.
- **One repo, ascending PR number, one at a time.** The repo is an explicit input; PRs
  are sorted numerically ascending and run strictly sequentially — never concurrently,
  since each merge moves the base the remaining PRs are measured against. No
  dependency analysis is performed; that is `kp-do-gh-ready-items`' job.
- **Fresh context per PR.** Each PR is a separate `/kp-do-gh-pr-loop <n>` run, launched
  through `run-child.sh` (its standard flag set) and waited on in the foreground — never
  a reused context. The model is the child's per-PR `model:*`
  resolution unless `--model` overrides it for the whole pass.
- **A park never ends the pass.** A PR that stalls, is merge-blocked, hits an
  unactionable finding, or raises a decision issue is left open by its child and the
  pass continues with the next PR; nothing is retried within the same pass.
- **A capacity hit ends the pass, and is not a park.** A `capacity=` other than `none` on
  `run-child.sh`'s result line (§2.3) records `capacity-limit`: no decision issue, no board move,
  the PR left as the child found it, the remaining PRs `not-attempted`, and exactly one
  message — the §4 wrap-up, with the reset time. Never a retry or wait loop.
- **Outcome from GitHub state, not logs, not exit codes.** Merged / parked /
  blocked-on-decision is read from `gh pr view`, the linked issue's state, and the
  open decision issue carrying `blocks: <R>#<pr>` — never parsed from child stdout,
  and never inferred from a child's exit status. The one log read is the `capacity=` field
  of `run-child.sh`'s result line (§2.3), read before classification.
- **Never reads human-only content into context** — the `<!-- human-only -->` fence is
  skipped wherever PR and issue bodies are read.
- **The operator is messaged once per pass.** The §4 wrap-up is the pass's only
  message; a decision a child files pings on its own, and the children's wrap-ups are
  dropped because they run headless.
- **Launch from a primary checkout**, auto-cloned when missing, never inside a child
  worktree — the children create their `<repo-name>-review-pr-*` /
  `<repo-name>-fix-pr-*` siblings beside it.
- **Idempotent/resumable.** Re-running re-lists open PRs, so merged ones simply drop
  out of the set; a parked PR is re-driven from current GitHub state and its child
  reuses the existing decision issue rather than stacking duplicates. `--from` resumes
  an interrupted pass at a given number.
