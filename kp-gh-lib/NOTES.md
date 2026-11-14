# NOTES — kp-gh-lib

## GitHub API budget (family convention)

Projects v2 is the only expensive part of the GitHub API the kp-* skills use. The GraphQL
budget is **5,000 points/hr** and a query's cost scales with the nodes it returns, so:

- **Keep a skill's preamble ≤5 points on the paths it normally takes.** `preamble.sh` is
  that whole preamble in one call: 2 points on `--no-item`, 3 on `--issue`, 4 on
  `--pr`, plus one each for a node-id `--project`, an issue that has to be added to the
  board, and an organization-owned board (the `user(login:)` miss below) — so 5 on the common paths and
  6–7 where those add up. `resolve-board.sh` and `item-id.sh` cost 1 point each. Never use `gh project field-list` (102 points) or a board-wide
  `gh project item-list` (305 points / 582 KB on a 254-item board).
  `kp-do-gh-ready-items` is the one skill that enumerates a whole board, and does it with
  `ready-sweep.sh`'s narrow paginated query (3 points).
- **Pick fields by name client-side, never `field(name:"X")`.** When the board lacks the
  field GraphQL answers with a `NOT_FOUND` error and `gh api graphql` exits 1, which makes
  a "no such field → skip" fallback unreachable. Fields that are not single-select come
  back as empty nodes and are ignored.
- **A user-login miss is the org-owned signal, not a failure.** `user(login:)` on an
  organization also exits 1, printing `NOT_FOUND` beside `"data":{"user":null}`;
  `resolve-board.sh` then re-runs with `organization(login:)`.
- **Add an item with the mutation, not `gh project item-add`.**
  Measured, the CLI costs **4 points** — it re-resolves the project and the content itself — where
  `addProjectV2ItemById` on an already-known project id and issue node id costs 1. That
  is why `item-id.sh` also returns the issue's `contentId`: the add needs no second
  lookup, and `preamble.sh` stays under its ceiling even when it has to add the item.
  Every creator adds through the mutation via `create-item.sh`.
- **Find one item from the issue side.** The issue's `projectItems` is 1 point; scanning
  the board for it is not. An issue can sit on several boards, so match `project.id` —
  never take the first node. The returned Status saves a redundant write when it already
  matches.
- **Find a merged item's dependents with issue search, never the board.**
  `unblock-dependents.sh` runs two REST `search/issues` queries for the quoted
  `"blocked-by: …"` phrase and touches the board only per confirmed dependent. Search is
  over-broad (and unquoted, `blocked-by:` reads as an unknown qualifier), so every hit is
  a candidate until its marker line is read outside the human-only fence. REST search has
  its own limit of 30 requests/min, separate from the GraphQL points.
- **Find any other marker with `find-marker.sh`, never a prose recipe.** One REST search
  per written form of the value (two for an issue reference, one more with
  `--comments`), each hit confirmed by its exact line outside the human-only fence and
  `<details>`. It costs no GraphQL points and counts against the same 30 requests/min.
- **Ensure labels and resolve a repo code over REST, never the board.**
  `ensure-labels.sh` reads the repo's labels once (`repos/<repo>/labels`) and calls
  `gh label create` only for a label that is absent or recolored; `repo-code.sh` reads at
  most one page of the repo's `repo:<name>`-labelled issues. Both cost 0 GraphQL points.
- **Find an item's milestone from the issue side, never the board.** `milestone-of.sh`
  walks the sub-issue `parent` chain in one 1-point query — GitHub nests sub-issues at
  most eight deep, so one query reaches the root. `milestone-gate.sh` finds milestone
  epics with one REST search and walks down only the earlier milestones' sub-issue trees,
  1 point per page of children, stopping at the first milestone that still has open work.
  Two more searches, one for all audits and one for all audit-close decisions, complete
  its audit gate: three searches a call.
- **Read the remaining budget from `X-RateLimit-Remaining`** on a real call
  (`gh api -i graphql …`), **never from `gh api rate_limit`** — that reports the wrong
  bucket, and was observed returning `used: 0, remaining: 5000` while a live GraphQL
  response header on the same token showed `used: 2098, remaining: 2902`.
- **A secondary-limit `403` is a park/escalate reason, not a crash:** stop issuing calls,
  report the limit, and resume later — never retry in a tight loop.
- **Orchestrators pay the preamble repeatedly.** `kp-do-gh-task-loop` and
  `kp-do-gh-pr-loop` launch a fresh child per phase (and `kp-do-gh-ready-items` one
  `kp-do-gh-task-loop` per item), and `--project` carries only an owner and number, so
  every child runs its own preamble at 3–4 points. That is why both
  lookups must stay 1-point queries. `milestone-gate.sh --current` is the exception: 3
  searches, the project-repos query, and 1 point per page of milestone-epic children
  walked. A creating skill reaches it only through `milestone-place.sh`, whose `--cache`
  file keeps it to once per run.

## Waiting in a headless session (family convention)

`kp-do-gh-task`, `kp-fix-pr` and `kp-review-gh-pr` normally run as headless `claude -p`
children of the loop orchestrators, and `kp-resolve-spec-decision` and
`kp-resolve-spec-research` as children of `kp-resolve-spec-decision-auto`, so every build,
test, lint, CI or child wait inside them follows these rules — including
`kp-resolve-spec-decision`'s wait on its own `kp-do-gh-pr-loop` child, and
`kp-resolve-spec-research`'s waits on its resolver and `kp-do-gh-task-loop` children.

- **Why the turn must not end.** A headless session exits the moment the model ends its
  turn. `Bash`'s `run_in_background` and `Monitor` deliver their result as a notification
  to a still-live session; headless, none is left to receive it, and the process they
  started dies with the session. A child that backgrounds `./gradlew build` and ends its
  turn exits 0 with nothing committed, pushed or posted.
- **The rule.** Never end the turn while a command started in it is still running. Never
  use `run_in_background` or `Monitor` in a skill that can run headless — only a
  foreground `Bash` call blocks the turn.
- **A command that finishes within the 10-min foreground cap** (lint, unit tests, a short
  build): one foreground `Bash` call with an explicit `timeout` sized to the command, at
  most `600000`. Never rely on the 2-min default for a build or test run.
- **A command that may run past the cap** (a full build with integration tests or
  Testcontainers): the detached + sentinel pattern. The log
  `<log>` is a scratchpad file and its sentinel is `<log>.exit`, a **fresh pair for every
  launch** (for example `build-run<k>.log`, with `<k>` counting up within the run).
  A verify loop re-runs the build, and a reused path leaves the
  previous run's `<log>.exit` on disk, so the wait returns at once with a stale exit code
  and log while the new build is still running. Write both out as literal paths in every
  call, since shell variables neither persist between `Bash` calls nor reach the
  single-quoted `bash -c`. Launch:
  ```bash
  nohup bash -c '<cmd> > "<log>" 2>&1; echo $? > "<log>.exit"' >/dev/null 2>&1 & disown
  ```
  then wait in a foreground `Bash` call with `timeout: 540000`:
  ```bash
  until [ -f "<log>.exit" ]; do sleep 5; done; echo "exit: $(cat "<log>.exit")"
  ```
  If that call times out, issue the identical wait again, as often as needed — the
  sentinel is on disk, so re-waiting resumes where it left off. Read `<log>` and the exit
  code only once `<log>.exit` exists. (A bare `sleep <n>` is refused by the harness; the
  `until` loop is the supported wait.)
- **A headless `claude -p` child** (an orchestrator's build, review, fix or resolver
  phase): `~/.claude/skills/kp-gh-lib/scripts/run-child.sh`, which is that same pattern
  packaged — the detached launch with the family's standard flag set
  (`--permission-mode bypassPermissions --autocompact 150k --settings
  kp-gh-lib/scripts/headless-settings.json`, plus `--model` and `--chrome` when given), the sentinel
  derived from `<log>`, the foreground wait, and the capacity grep:
  ```bash
  ~/.claude/skills/kp-gh-lib/scripts/run-child.sh --log "<log>" --cwd "$PWD" --model M [--chrome] \
    -- "/kp-<skill> <args>"
  ~/.claude/skills/kp-gh-lib/scripts/run-child.sh --wait "<log>"
  ```
  The launch returns at once with `status: running` (exit 3). Each `--wait` is an
  ordinary foreground `Bash` call with `timeout: 540000` and returns either the child's
  result line, `exit=<code> capacity=<none|session-limit|weekly-limit> [reset='<time>']
  log=<path>` (exit 0), or `status: running` (exit 3) — in which case issue the identical
  wait again, as often as needed. `capacity=` is the check every caller must run before
  reading GitHub state: a child refused for quota exits 0 without touching GitHub, so
  anything but `none` is a capacity hit, not a result. A fresh `<log>` per launch, for
  the same stale-sentinel reason as above. A detached child outlives the session that
  launched it, running until it finishes or its `--timeout-min` fires, and appears in
  ListAgents only as an "interactive", possibly "busy", peer named after its cwd.
  `run-child.sh --list` shows every live child with its pid, elapsed time, cwd, log and
  prompt.
- **Several children at once** (`kp-do-gh-ready-items` §3, one stream per repo): an
  orchestrator with more than one child in flight waits on each in turn with
  `run-child.sh --wait "<log>" --wait-max-sec <s>`, one foreground call per child,
  collecting whichever returns a result line first, and never ends its turn while any is
  in flight. Concurrent children in different repos share the operator's Gradle daemons
  and build resources (CPU, memory, the Gradle user home); `run-child.sh`'s sweep spares
  `GradleDaemon` / `GradleWorkerMain` (`kp-gh-lib/scripts/run-child.sh`) so one child's
  exit never kills another's build. That is why concurrency stops at one child per repo
  and is accepted across repos.
- **A timed idle wait** (an orchestrator waiting between sweeps, e.g.
  `kp-do-gh-ready-items` §3.4): a foreground `Bash` call with `timeout: 540000` running
  a deadline `until` loop, at most 450 s per call:
  ```bash
  end=$(( $(date +%s) + 450 )); until [ "$(date +%s)" -ge "$end" ]; do sleep 5; done
  ```
  A longer wait is split into several such calls.
- **A CI poll** (`gh pr checks <n> --watch --interval 60`, or the capped re-poll loop):
  one foreground `Bash` call with `timeout: 600000`. The calling skill's bounded window
  and GraphQL point budget are unchanged.

## Run state across compaction (family convention)

- **The window.** Every `claude -p` launch in a `SKILL.md` passes `--autocompact 150k`.
  Measured 2026-09-13 across 768 local `kp-*` session transcripts, as peak per-request
  context (input + cache-read + cache-write tokens): median 74k, p90 122k, p95 151k, p99
  240k, max 305k. At 150k a typical run never compacts, and the long tail (40 runs, 26 of
  them `kp-do-gh-task`) compacts instead of paying for, and losing focus in, a 300k
  context. One window for every launch, not one per skill.
- **The hook.** Every such launch also passes
  `--settings ~/.claude/skills/kp-gh-lib/scripts/headless-settings.json`, unquoted so the
  shell expands `~`: launches run in other repos' checkouts, so both paths are absolute.
  The file defines one hook, `SessionStart` with matcher `compact`, which runs
  `restore-run-state.py` once compaction finishes and adds its stdout to the compacted
  context. Hooks from `--settings` fire in addition to the checkout's own
  `.claude/settings.json` hooks, so a repo's guard hooks stay active (probed on Claude
  Code 2.1.270). There is no `PreCompact` hook: facts read after compaction equal the
  ones before it.
- **The state file** is `~/.claude/skills/kp-gh-lib/state/run-<session-id>.md`
  (gitignored), one per session, keyed by `$CLAUDE_CODE_SESSION_ID` — the `session_id`
  the hook receives is the same value (probed on 2.1.270). A writer rewrites the whole
  file each time, from `Bash`:
  ```bash
  mkdir -p ~/.claude/skills/kp-gh-lib/state
  cat > ~/.claude/skills/kp-gh-lib/state/run-"$CLAUDE_CODE_SESSION_ID".md <<'EOF'
  issue: #<n>
  pr: #<pr>
  branch: <branch or headRefName>
  worktree: <absolute worktree path>
  base: <base branch the worktree was created from>
  acceptance criteria:
  - [x] <criterion> — <how it was verified>
  - [ ] <criterion>
  EOF
  ```
  Omit `issue:` when the run has no issue, `pr:` until it is known, and `base:` outside
  `kp-do-gh-task`, which writes it at §3.2 (§ *Milestone branch*). The skills run
  from the main checkout and act on the worktree with `git -C`, so the hook takes the
  worktree from this file, never from its own cwd, and appends `head: <sha>` read live
  from it. A writer ends its run with
  `rm -f ~/.claude/skills/kp-gh-lib/state/run-"$CLAUDE_CODE_SESSION_ID".md`.
- **Contents.** Those lines only — never a token, a credential, or issue-body text beyond
  the criterion lines. The hook makes no network calls and always exits 0; with no state
  file for the session (every skill but the writers) or unreadable input it prints
  nothing.
- **Writers.** `kp-do-gh-task` writes the file once its §1.3 criteria are extracted and
  its §3 worktree exists, ticks each criterion as §4 proves it, adds `pr:` at §6.3 and
  deletes the file in §9, on success or a stop. `kp-fix-pr` writes it at §2 with its
  findings and the linked issue's criteria, ticks them in §3 and deletes it in §8.
  `kp-review-gh-pr` writes it at §3 with its §1.5 criteria, ticks them in §4.1 and
  deletes it in §7; its `worktree:` line is present only when a worktree exists (a review
  whose checks CI covers creates none), so the hook then prints no `head:` line.

## Human-only fence (family convention)

Every created issue body starts with a short plain-language description **for
human readers**, fenced by HTML comments:

```
<!-- human-only:start (not LLM/spec context) -->
> **For humans:** <1–2 line summary of what the task is / why it exists>
<!-- human-only:end -->
```

Rationale and rules (every `kp-*` skill that creates an issue follows this):
- It is a **reading aid** so someone skimming the board needn't decode the
  `spec-ref`. The blurb is derived, never authoritative. On a `type:coding` item the
  sections below the fence are the contract (`kp-gh-lib/NOTES.md` § *Coding item
  body*), pinned to the synced spec SHA — a builder reads the body, not the spec doc.
- It is **fenced with HTML comments** so it renders cleanly on GitHub yet the
  fence is detectable in the raw body. When a skill reads a body (dedup,
  classification, marker extraction), it **skips everything inside the fence**. A skill
  that strips the fence from a body runs `kp-gh-lib/scripts/body-parts.py strip`.
- All machine markers (`spec-ref:`, `blocks:`, `blocked-by:`, `resolves:`) live
  **outside** the fence, so dedup against the exact `spec-ref:` line is unaffected.
- The fence markers are byte-identical everywhere they appear
  (`<!-- human-only:start (not LLM/spec context) -->` / `<!-- human-only:end -->`)
  so the create step and the skip rule always agree.

## Human-gated item body (family convention)

Covers every `type:decision`, `type:question` and `type:conflict` issue a kp-* skill
creates: `kp-sync-spec-tasks` §5, `kp-backfill-contract` §1.4, `kp-do-gh-task` §1.4, `kp-do-gh-pr-loop-escalate` §1.3,
`kp-decompose-gh-task` §3, `kp-resolve-spec-decision` §4.3 and `kp-audit-alignment` §7,
each after § *Before raising a human-gated item* — plus the research gate item `kp-resolve-spec-research` §4
raises, and the goal question `kp-resolve-spec-decision-auto` §4.0
rewrites a decision into, or a creator raises directly (§ *Goal questions*). It does
**not** cover `type:research`, which is a spike task rather than a question and
keeps its own body.

The operator answers these items, so they are written in the operator's words, not the
raising agent's: the question first, one decision per question, and the evidence folded
away. The creating skill still owns the mechanics (dedup, labels, assignee, priority,
which markers it writes, the `__ISSUE__` post-create substitution). This section fixes
the title, plus the body's order, length and vocabulary.

### Template

The human-only markers and their position are unchanged.

```
<!-- human-only:start (not LLM/spec context) -->
> **For humans:** <what is stuck> — <what you need to decide>. 1–2 lines, no identifiers.
<!-- human-only:end -->

spec-ref: …
blocks: …

## The question
<One sentence ending in "?", answerable by picking an option.>

## Why it matters
<2–4 plain sentences: what is blocked, what goes wrong if decided badly. One concrete example.>

## Options
**A — <short name>.** <Effect the operator or a user would notice.> *Good:* … *Cost:* …
**B — …**

**Recommendation:** B (confidence: high | medium | low), because … (or "No recommendation", and why)

## To resolve
Reply "A" / "B" (or your own answer in a sentence), then run `/kp-resolve-spec-decision <n>`.

<details><summary>Details for the resolving agent</summary>

REQ/AC refs, file:line, findings, SHAs, log paths, related issues
</details>
```

- The marker block below the fence holds every machine marker the creating skill writes:
  `spec-ref:`, `blocks:`, `blocked-by:`, plus skill-specific ones such as
  `resolves:`, `slice:` and `parent:`. A goal question adds `goal-ref:`, and a restored
  decision carries `goal-answered:` (§ *Goal questions*).
- `<n>` is the item's own number. The body file carries `__ISSUE__` there, and the
  creating skill substitutes the number after `gh issue create`.
- **A research gate item's resolution prompt names a different command.** Its answer
  feeds the research on the `type:research` item it blocks, so "To resolve" reads
  `Reply "A" / "B" here on #<n> (or your own answer in a sentence), then run
  /kp-resolve-spec-research <research-n>` — never `/kp-resolve-spec-decision`.
- Every Recommendation names its confidence (§ *Confidence and creator-decided items*
  below); a `type:decision` whose every Recommendation is `high` is decided by its
  creator at filing, and any other `type:decision` may be answered by
  `kp-resolve-spec-decision-auto`.

### Confidence and creator-decided items

Every Recommendation names its confidence; "No recommendation" has none.

- **`high`** — the text the creator read (the spec, the code, the PRs and issues it
  cites) shows the recommended option meets what the spec and the existing code already
  require, and every other option breaks a stated requirement, contradicts existing
  behaviour, or is worse at no benefit: the bar `kp-resolve-spec-decision-auto` §3 calls
  clearly best. A choice the domain layer determines (§ *Before raising a human-gated
  item*, branch 3) is `high`.
- **Never `high`** when the options trade off something only the operator can weigh
  (cost against speed, user-facing taste, business priority, scope); when evidence
  needed to choose is missing or could not be read; when choosing needs a fact written
  nowhere; or when the best answer is not a listed option. A goal question, a research
  gate item (`kp-resolve-spec-research` §4), an audit-close decision (§ *Audit gate*), a
  `kp-do-gh-pr-loop-escalate` item, a `type:question` or `type:conflict`, and the
  open-gap item § *Settling a failing draft* raises are never `high`. An audit
  `goal-risk` decision is an ordinary technical decision this rubric applies to.
- **`medium`** — a real recommendation with one of those reservations. **`low`** — a
  lean.
- With several questions, each Recommendation carries its own confidence.

A **creator-decided item** is a `type:decision` — the technical item itself, never a goal
question raised in its place — whose every Recommendation is `high`. Its creator decides
it at filing: it writes the decision comment below to a file, with `__ISSUE__` where the
number goes, and passes `--decided-body-file <file>` to `create-item.sh`, which posts the
comment right after the body substitution, files the item with Status `Ready` unless the
caller set a Status, and sends no Telegram ping unless the comment failed or `Ready` did
not land (§ *Operator notifications*). The body and its "To resolve" line stay written
for the operator. From there the item is an answered one: `kp-do-gh-ready-items` §1.8
resolves it with a headless `kp-resolve-spec-decision` on its next pass, batched with
that pass's other answered decisions into one spec PR, which reads the
comment as a §3 (c) agent decision, and a later human comment that picks an outcome
overrides it, exactly as for a `kp-resolve-spec-decision-auto` decision. The override
window is the time to that pass; there is no grace period. The creators that decide this
way are `kp-do-gh-task` §1.4, `kp-sync-spec-tasks` §5, `kp-decompose-gh-task` §6,
`kp-resolve-spec-decision` §4.3 and `kp-audit-alignment` §7.

The decision comment, with `<creator-skill>` the skill whose section makes the
`create-item.sh` call:

```
**Decision (agent, via /<creator-skill>, at filing):** <answer — B, or 1B 2A>

Expanding <answer> per the issue body: <option name, per question>.

<the Recommendation's reasons: what each other option breaks or loses, with the deciding
spec phrase and its section when the domain layer settled it>

The filing agent decided this because its recommendation met the high-confidence bar
(kp-gh-lib/NOTES.md § "Human-gated item body" → "Confidence and creator-decided items");
the operator did not pick it personally. To override it, comment your own decision and
run `/kp-resolve-spec-decision __ISSUE__` — or, once this issue is closed,
`/kp-resolve-spec-decision __ISSUE__ --decision "<your decision>"`.

<!-- decision-source: <creator-skill> -->
```

A `type:decision` that is not creator-decided may instead be answered by
`kp-resolve-spec-decision-auto`, which decides only when a fresh subagent finds one
option clearly best and posts a marked agent-decided comment, then runs
`kp-resolve-spec-decision`, which drives the resulting spec PR to merged with a headless
`kp-do-gh-pr-loop` exactly as it does for the operator's own decision. When no option is
clearly best on the requirement, the subagent first reads the spec's domain layer
(§ *Decision layers*): a goal that settles the choice decides it, and a goal the spec
never states turns the item into a goal question. On a research gate item it runs a
headless `kp-resolve-spec-research` instead of `kp-resolve-spec-decision`. The body and
its "To resolve" line stay written for the operator.

### Per-type variation

- **`type:decision` / `type:conflict`:** "## Options" is required. For a conflict, the
  options are which source wins, or a reconciled wording.
- **`type:question`:** use "## Options" when there is a finite set of answers. Otherwise
  replace it with "## What I need from you", which states exactly what shape of answer
  is needed (e.g. "a retention period in days"); "To resolve" then asks for that answer.

### Several questions in one impasse

They stay in **one item**. Dedup on `blocks:` is unchanged.

- "## The question" becomes "## Questions", with `### 1. <question>?`, `### 2. …`. Each
  question gets its own "Why it matters", Options and Recommendation, and can be
  answered on its own.
- Option letters restart for each question. "To resolve" asks for answers like `1B 2A`.
- **At most three questions per item.** If the impasse has more, ask the three the
  blocked work needs first and say so in question 1's "Why it matters". List the rest
  in `<details>` as open follow-ups.

### Goal questions

`kp-resolve-spec-decision-auto` §4.0 rewrites a `type:decision` item **in place** as a
`type:question` when its answer turns on a domain goal the spec never states
(§ *Decision layers*), and a creator raises one directly in that shape in place of the
technical item it drafted (§ *Before raising a human-gated item*). The goal question
follows the template, with these differences:

- **Blurb:** which technical choice is stuck, and which goal is missing.
- **Markers:** every marker line the decision (or the drafted technical item) carried
  stays byte-identical, and one `goal-ref: <key>` line is added beside them. `<key>` is
  the domain section the missing goal belongs in: `<doc-slug>#<heading-path-slug>`,
  derived as `kp-sync-spec-tasks` §1 derives a key, or `<brief-file>#<heading-path-slug>`
  for the brief. A marker line is a line outside the human-only fence and `<details>`
  that starts with a family marker: `spec-ref:`, `blocks:`, `blocked-by:`, `resolves:`,
  `slice:`, `parent:`, `milestone:`, `spec-pr:`, `goal-ref:` or `goal-answered:`.
- **Questions:** one to three domain questions, with options described by their business
  effect. "## What this settles" follows them: one line per domain option, naming the
  option of each original question it would settle — `A → B`, or `1A → 1B 2A`. An
  original question with no options ("## What I need from you") is named by the answer
  the domain option implies, in a few words.
- **`<details>`:** the original question(s) in short form, and the evidence.
- **Restore:** once the goal's spec PR merges, `kp-resolve-spec-decision` puts the
  original title and body back from the escalation comment, adds
  `goal-answered: <key> via <pr-url>` after its last marker line (after the human-only
  fence when it has none, else at the top), and swaps the label back to the type the
  comment's `restore-type:` line names — `type:decision` when it has none, as on every
  `kp-resolve-spec-decision-auto` escalation — so a creator-raised question or conflict
  comes back as itself, never as a decision the auto run may answer. `goal-answered:`
  lines accumulate, one per climb, and the auto run never escalates an item to a key it
  already lists.

Every search for these markers is a `find-marker.sh` call
(`~/.claude/skills/kp-gh-lib/scripts/find-marker.sh <repo> goal-ref <key>`), which quotes
the phrase and confirms each hit by its marker line outside the fence and `<details>`.

### Writing rules

- **Title:** the question itself in plain words, ≤70 characters after the
  `[<REPO-CODE>] ` prefix, with no REQ/AC ids. With several questions, it names their
  shared subject.
- **Above `<details>`:** no REQ/AC ids, file paths, SHAs or code identifiers. Issue/PR
  numbers appear only in "Why it matters", to say what is blocked. A name the operator
  actually sees (a setting key, a UI label) may appear. Define any other term the
  operator must know in one clause. The marker block is exempt, because markers are
  read by skills, not the operator.
- **Options:** describe each by its observable effect, not its implementation.
- **Length:** about 200 words or fewer above `<details>` for each question.
- **Markers:** every machine marker stays outside both the human-only fence and
  `<details>`. `<details>` is not a fence, so readers still see its contents. That is
  intended: the resolving agent needs them.

### Self-check before `gh issue create`

Ask: "Could the operator answer from the part above `<details>` alone, without opening
the spec or the code?" If not, rewrite it.

### Worked example

`example-org/shop-spec#24` rewritten, top section only. The original title and blurb
began with "REQ-ORDER-004 reservation lifetime and expiry", and its review findings, SHAs
and log paths were mixed in with the options.

> **Should an order waiting for payment keep its stock reserved?**
>
> **The question:** When a customer's payment is still being confirmed, should the items
> in the order stay reserved for them?
>
> **Why it matters:** Each item has limited stock. A bank confirmation can take hours,
> and the spec does not say whether the waiting order holds its items until then.
> PR #23 cannot merge until this is decided.
>
> **A — Release while waiting.** Other customers can buy the items, and the order is
> filled from stock again when the payment confirms. *Good:* nothing sits unsold
> overnight. *Cost:* a paid order may find an item gone and need a refund.
> **B — Hold the reservation.** Nobody else can buy those items until the payment
> confirms or fails. *Good:* a paid order can always be filled. *Cost:* stock waiting on
> a slow payment cannot be sold for hours.
> **C — Leave it to the checkout build.** *Good:* unblocks PR #23 today. *Cost:* the
> behavior gets chosen in code, not in the spec.

## Coding item body (family convention)

Covers every `type:coding` issue a kp-* skill creates. It is the coding-item counterpart
of § *Human-gated item body*: an agent must be able to build and review the item from its
body alone. The creating skill still owns the mechanics (dedup, labels, assignee,
priority, which markers it writes). This section fixes the body's sections, their line
forms, and the check a draft passes before `gh issue create`. `lint-item.py` is the test:
a body it fails (exit 1) does not meet the contract and is `needs-contract`.
`/kp-backfill-contract` selects by that same lint and converts such
bodies, and the loops never launch a build for an item labelled `needs-contract`.

### Template

The human-only markers and their position are the same as on every created item.

```
<!-- human-only:start (not LLM/spec context) -->
> **For humans:** <1–2 plain lines>
<!-- human-only:end -->

### Goal
serves: G-<n>[, G-<m>]            # or: serves: G-<n> via <owner/repo>#<parent>
<1–2 sentences: the outcome, and how it advances that goal>

### Scope
- <file or module> — <what changes>

### Out of scope
- <adjacent thing a builder might touch, and must not>

### Context
spec: <owner/repo>@<sha>:<path>#<anchor>     # anchor = heading slug or a REQ id
code: <path>[#<symbol>]
decision: <owner/repo>#<n>
dismissed: <ref> — <why it does not govern this item>

### Rules
> <binding spec text, quoted word for word>
> — <owner/repo>@<sha>:<path>#<anchor>

### Acceptance criteria
- [ ] <observable outcome> — proof: <test name | command | file/field to inspect>

### Verify
<exact command(s) that prove the item done, e.g. from the repo CLAUDE.md "## Verify">

<existing marker lines: spec-ref:, slice:, parent:, blocked-by:, resolves:, …>
```

`### Context` takes any number of each line form, and a form that has nothing to name is
left out.

### Rules

- **The body is the contract.** A builder or reviewer loads exactly the body plus what
  `kp-gh-lib/scripts/read-context.sh` returns for it — never a whole spec doc.
- **`spec:` lines** pin a commit SHA and name one section: a heading slug as GitHub
  renders anchors, or a REQ id.
- **`serves:`** is copied from the `Serves:` line of the requirement or section that
  `spec-ref:` names, never invented. Decomposed children inherit it. Enabling and
  follow-up items use `serves: G-<n> via <owner/repo>#<parent>`.
- **No-spec repos.** When the body has no `spec-ref:` marker and no `spec:` line,
  `serves:`, `spec:` lines and the cross-reference sweep are optional. Every other
  section is required.
- **Rules quotes** are for short binding text, about 15 lines or fewer per quote. Longer
  text becomes a `spec:` line.
- **Every acceptance criterion names its proof** after `— proof:`.
- **Size is advice only.** When an item looks large, the creator suggests a split and
  says why. It never trims context to make the item look smaller.
- **Cross-reference sweep.** Every outgoing reference in a loaded spec section (`§n`,
  `REQ-*`, `ADR-*`, `decided in #n`) must be one of:
  - loaded by another `spec:` line;
  - quoted in Rules;
  - a `decision:` line;
  - listed under `dismissed:` with a reason.

  A reference to `G-<n>` is covered by the goal frame.
- **Goal frame.** For a spec-backed item, `read-context.sh` always adds the spec's goals,
  quality priorities and non-goals section, taken at the same pinned commit.

### Cold-reader check

Run it after `lint-item.py` passes and before `gh issue create`.

- **Who runs it:** one fresh foreground `Agent` subagent, type `Explore`,
  `model: sonnet`. Its only input is the stdout of
  `read-context.sh --body-file <draft>` — not the creator's conversation, not the spec.
- **What it answers**, each with `ok` or a list of `gap: <what> — <why>` lines:
  1. Can I build this without asking anything?
  2. Can each acceptance criterion be proven as written?
  3. Is any rule referenced but not loaded?
  4. Is anything ambiguous?
  5. Does the scope conflict with a non-goal, or trade against a higher-ranked quality
     priority?
  6. Does every acceptance criterion advance the stated goal?
- **On a gap:** the creator fixes the draft, then runs lint and the cold reader again.
- **After two failed rounds:** the creator splits the item (§ *Creating an item* →
  *Atomicity bar*), or raises it per § *Before raising a human-gated item*. A
  question-5 conflict always goes through § *Before raising a human-gated item*.

### Settling a failing draft

Covers a coding draft that a skill which may not stop to ask the operator is about to
file — `kp-audit-alignment` §7, a follow-up per § *Filing a follow-up item*,
`kp-resolve-spec-decision` §4.2 — when it still fails `lint-item.py` or the cold reader
after the two repair rounds. Such a draft never gets the `needs-contract` label: it is
settled, then filed complete or raised as one human-gated item. Apply the steps in order.

1. **Sort the gaps.** Sort every remaining lint `FAIL` line and every cold-reader gap as
   **settled** or **open**:
   - **Settled:** the code, the spec or the draft's own Scope answers it — a technical
     fact (§ *Before raising a human-gated item* branch 2) or a domain phrase that
     decides it (branch 3). A missing acceptance criterion whose behaviour Scope already
     states is settled. Keep each answer with its source (`path:line`, spec section, or
     Scope sentence).
   - **Open:** everything else — a choice no source settles, a human preference, or
     branch 4's missing goal. A `FAIL spec-gap` is always open, as is a question-5
     conflict and any `FAIL` the body cannot fix (`dirty-spec`, or `context-resolve` on a
     missing section).
2. **Fold and re-check.** Write each settled answer into the draft — Scope, Context,
   Rules, or an acceptance criterion — then run lint and the cold reader once more. This
   pass is not a third repair round.
3. **Pass → file.** Lint exits 0 and the cold reader answers `ok` on every question →
   file the coding item as normal.
4. **Any open gap, or still failing → do not file.** Any open gap wins, even when every
   other check passes. File no coding item; raise exactly one human-gated item instead,
   its body per § *Human-gated item body* (at most three questions; it holds only open
   gaps, so it is never creator-decided):
   - **Type**, by the open gaps, first match wins: a `FAIL spec-gap` → `type:question`,
     the goal question; a question-5 conflict, or a `FAIL` the body cannot fix
     (`dirty-spec`, `context-resolve` on a missing section) → `type:conflict`, naming the
     spec problem; anything else → `type:decision`, one question per open gap.
   - **Climb first**, per § *Before raising a human-gated item*, for every type. A goal
     the spec states settles the gap: fold it in and return to step 2. An existing open
     goal question still means this item is raised, with `blocked-by:` that question.
     That section's "create the technical item" branch does not apply: the item is the
     held draft below.
   - **The climb returns once.** The return to step 2 happens at most once per draft; a
     draft that still fails after it continues with this step.
   - **No `blocks:` line** — no coding item exists yet.
   - **More than three open gaps** are grouped into at most three questions by the file
     or decision they turn on. It is still exactly one item.
   - **Evidence.** Its `<details>` holds the settled answers, then a line
     `<!-- kp-gh-lib:held-draft -->`, then the full draft inside a code fence one
     backtick longer than the longest backtick run in the draft (as `kp-backfill-contract`
     §1.4 fences "Previous body"). Marker lines inside that fence are evidence, not
     markers of the raised item.
   - **Markers**, outside the fence: the draft's `spec-ref:` and `serves:` when it has
     them, `audit-finding:` for the audit, and always
     `held-draft-key: <repo>#<first 12 hex of the sha1 of the draft's title>`. A
     `type:question` raised for a `FAIL spec-gap` also takes the `goal-ref:` marker and
     the escalated-restore comment exactly as § *Before raising a human-gated item*'s
     "None does" branch writes them.
   - **Dedup.** Before raising, search the filing repo:
     `~/.claude/skills/kp-gh-lib/scripts/find-marker.sh <repo> held-draft-key <value>`.
     A hit is reused and nothing new is raised — for every
     caller, with or without `audit-finding:` or `spec-ref:`.
   - **A check that cannot run** (step 5) takes precedence over open gaps from an earlier
     round: the gaps cannot be confirmed against a current check, so the draft goes
     unfiled.
5. **A check that could not run** (lint exit 2 or 4, `read-context.sh` exit 1 or 2) →
   rerun that one check once; the retry is not a repair round. Still unable to run → file
   nothing. The run report lists `unfiled: check could not run — <title> (exit <code>)`,
   and the calling skill keeps its own durable record of the work (`kp-audit-alignment`
   §7, `kp-fix-pr` §3, `kp-resolve-spec-decision` §4.5 and §4.8).

### Drafting from a spec section

How `kp-sync-spec-tasks` §4a drafts and checks a new coding item's body, and the rules
`kp-backfill-contract` §1.2–§1.4 reuse when it converts an old one. A bare `§0.<n>` cite
below names the calling skill's own §0 step — both skills number those steps alike — and
every other bare `§` cite names a `kp-sync-spec-tasks` section.

#### Draft

The body follows `~/.claude/skills/kp-gh-lib/NOTES.md` § *Coding item body*. A builder
loads only the body and what `read-context.sh` returns for it, so everything that governs
the requirement goes into the body. `<sha>` is the §0.10 synced SHA, `<spec-repo>` its
repo, and an anchor is the REQ id, or the heading slug for a derived key (§1).

1. **Spec gap first.** A requirement with no `Serves:` line is a **spec gap**: it gets
   no draft and no coding item. Report `spec-gap <ref> — no Serves: line` and raise
   it as a spec fix, below.
2. **Goal.** `serves:` copied from the requirement's `Serves:` line, never invented,
   plus one sentence: the outcome, and how it advances that goal.
3. **Scope / Out of scope.** From the requirement text and its routing (§0.5): Scope
   names what changes in `<ref-repo>`; Out of scope names the neighbouring requirements
   and repos a builder might reach into.
4. **Context.**
   - `spec: <spec-repo>@<sha>:<path>#<anchor>` for the requirement itself;
   - one `spec:` line per cross-cutting section the requirement references (`§n`,
     another `REQ-*`, an ADR), unless a Rules quote carries it;
   - `decision: <owner/repo>#<n>` per decision already folded in — a
     `decided in <owner/repo>#<n>` note in the requirement, or a closed human-gated
     issue carrying this ref;
   - `code: <path>` for a routed ref only: the files §3's verdict line names that the
     work touches. An unrouted ref has no checkout to read and carries none;
   - `dismissed: <ref> — <why>` for any other outgoing reference, so the contract's
     cross-reference sweep passes.
5. **Rules.** Quote word for word the binding sentences of the requirement and of the
   sections it references, each attributed as `> — <spec-repo>@<sha>:<path>#<anchor>`.
   A quote longer than the contract's limit becomes a `spec:` line instead.
6. **Acceptance criteria.** The requirement's ACs, each rewritten as
   `- [ ] <observable outcome> — proof: <test name | command | file/field to inspect>`.
7. **Verify.** The `## Verify` block of `<ref-repo>`'s `CLAUDE.md` — for a routed ref
   `git -C <path> show origin/<branch>:CLAUDE.md` (`<branch>` the area's `branch` from
   `repo-roots.sh`: `release/M<k>` when that origin has it, else the default branch), else
   `gh api repos/<ref-repo>/contents/CLAUDE.md -H 'Accept: application/vnd.github.raw'`.
   When the block is absent, write the test command that `CLAUDE.md` names, else the
   one its README names, and report `no-verify-block <ref-repo>`.
8. **Markers** after the sections, outside the fence: `spec-ref: <key>` and the §5
   `blocked-by:` lines.

Write the draft to `/tmp/kp-sync-spec-tasks-<key-slug>.md` (`<key-slug>` the key with
every character outside `[A-Za-z0-9-]` replaced by `-`).

**Raising a spec gap.** Once per requirement: the §2.1 dedup already skips a ref with an
open human-gated item, so a later run neither drafts nor raises it again. The item is a
`type:question` asking which goal the requirement serves, built like every §5
*Unclear requirements* item — `spec-ref: <key>`, `blocks: <key>`, the
`/kp-resolve-spec-decision <n>` prompt, assignee, priority, repo identification — with
the spec's goals as its options. It climbs per §5 *Climb before raising*: a goal the
domain layer clearly names is quoted in the Recommendation, and a goal the spec never
states is raised as the goal question in its place. `kp-resolve-spec-decision` adds the
`Serves:` line, and the next run creates the coding item. On dry-run, report what would
be raised.

#### Check

1. **Lint.** From the run's repo root,
   `~/.claude/skills/kp-gh-lib/scripts/lint-item.py --repo <ref-repo> --body-file <draft>`,
   adding `--code-root <code-root>` (§0.9) for a routed ref. Exit 1: fix every `FAIL` line and run
   it again; a `FAIL spec-gap` is not fixable in the draft — drop the draft and handle
   the ref as a spec gap (Draft step 1). Exit 4 (a fetch failure) or 2: **stop the
   run** with that message — never file an item on an unchecked draft. Keep the final
   `INFO` line for §6.
2. **Cold reader.** Run `~/.claude/skills/kp-gh-lib/NOTES.md` § *Cold-reader check* on
   the linted draft:
   `~/.claude/skills/kp-gh-lib/scripts/read-context.sh --body-file <draft> --repo <ref-repo>`
   from the same root, with the same `--code-root`. Save its stdout to a file and have
   the subagent read that file and nothing else. Exit 3 (something unresolved) is a gap
   in the draft; exit 1 (a fetch failure) or 2 **stops the run**. On a gap, fix the
   draft and run step 1 and this step again.
3. **Two failed rounds.** This skill files one item per requirement and does not split
   it — `kp-decompose-gh-task` splits a filed item — so a draft that still fails is
   raised as a human-gated item for the ref per §5 *Unclear requirements* and
   *Climb before raising*, with the remaining gaps as its evidence, and no coding item
   is created. A question-5 conflict (scope against a non-goal or a higher-ranked
   quality priority) always goes this way. On dry-run, report what would be raised.
4. **Size.** A draft that still looks large gets a split suggestion in §6 saying why;
   never trim its context to shrink it.

**Budget.** The cold reader is one `Explore` subagent, `model: sonnet`, per new coding item, run again only
after a gap fix. It never runs for a skipped ref, so a re-run on an unchanged spec runs
none. `kp-sync-spec-tasks` §6 reports how many ran. In `kp-backfill-contract`, §1.4's
stale-label pass also runs one cold reader per labelled item whose lint exits 0, and its
§1.5 counts those too.

### Worked example

`example-org/shop-api#70` implemented coupon validation, working from TECH_SPEC §5.1. It
did not load TECH_SPEC §8, which requires a `CouponRejected` audit event when a coupon
cannot be applied.

Under this convention the sweep catches that before creation. The loaded section refers
to `§8`, and no `spec:` line loads §8, no Rules quote carries it, and no `decision:` or
`dismissed:` line covers it, so the sweep flags `§8` as uncovered. The fix is one of:

```
### Context
spec: example-org/shop-spec@<sha>:TECH_SPEC.md#8-<heading-slug>
```

or, since the binding text is short, a Rules quote of the §8 sentence requiring the
`CouponRejected` audit event, attributed to the same pinned `<sha>:TECH_SPEC.md#…`.
Either way the cold reader's question 3 then answers `ok`.

## When an item is human-gated (family convention)

Covers every skill that raises a `type:decision`, `type:question` or `type:conflict`
item — `kp-sync-spec-tasks` §4–§5, `kp-backfill-contract` §1.4, `kp-do-gh-task` §1.4, `kp-do-gh-pr-loop-escalate` §1.2–§1.3,
`kp-decompose-gh-task` §3, `kp-resolve-spec-decision` §4.3,
`kp-resolve-spec-decision-auto` §4.0 — and the questions `kp-create-gh-item` §1 puts to
the operator. Each creator climbs § *Decision layers* before it raises one (§ *Before
raising a human-gated item*), and `kp-create-gh-item` §1 climbs before it asks.

- **Only technical and feature unknowns, and the domain goals § *Decision layers*
  escalates, are human-gated:** what to build or how to build it — behavior, interface,
  technical approach — is genuinely unknown, or the domain goal that would settle it is
  unwritten (§ *Goal questions*).
- **Order never is.** Which requirement or item comes first, which milestone something
  lands in, and a dependency cycle are the skill's to settle under § *Milestone
  sequencing*, and its run report says what it settled. No item is raised and the
  operator is never asked.
- **`type:conflict` means spec docs contradict each other on what to build**, never on
  when to build it. It also records a reviewer/fixer disagreement on one finding
  (`kp-do-gh-pr-loop-escalate`'s `unactionable-finding`). In a project with no spec
  repo, `kp-resolve-spec-decision` § *No-spec-repo branch* resolves `type:decision`,
  `type:question` and such a `type:conflict` by folding the answer into the body of the
  coding item it blocks.
- **A dependency cycle is broken, not escalated.** The acyclicity walk drops the edge that
  would close it and the run reports that edge — even when the spec text states the cycle.

## Decision layers (family convention)

Business and domain goals drive feature decisions, and feature decisions drive technical
ones. `kp-resolve-spec-decision-auto` §3–§4.0, `kp-resolve-spec-decision`'s
*Goal-answered branch*, every creator of a human-gated item (§ *Before raising a
human-gated item*) and `kp-create-gh-item` §1 apply these rules; they point here and
never restate them.

- **Domain layer (why):** every spec section whose heading contains, case-insensitively,
  *overview*, *positioning*, *goals*, *non-goals*, *scope*, *personas*, *journeys*,
  *domain language*, *glossary* or *contexts*, and every subsection of such a section
  whatever its own heading says (a *Quality priorities* subsection under a *goals*
  heading is domain layer); any brief the spec declares as its requirements or design
  authority; and the business rows of its resolved-decisions log. Headings are matched by
  these words — there is no config key.
- **Feature layer (what):** functional requirements and their acceptance criteria
  (`REQ-*`).
- **Technical layer (how):** architecture, stack, data model, operations, and every other
  section.
- **Climb rule:** a decision the current layer cannot settle is settled from a higher
  layer when that layer's text determines it. When the higher layer is silent, the
  question is asked at the layer where the missing fact belongs, never below it.
- **What a domain-derived decision cites:** beside the deciding phrase and its section,
  the goal's `G-<n>` id or the ranked quality priority that settles it, when the spec
  carries them (a `kp-project-spec` spec does).
- **The domain layer is the operator's.** No agent answers a domain-layer question.

### Before raising a human-gated item

Covers the creators `kp-sync-spec-tasks` §4–§5, `kp-backfill-contract` §1.4, `kp-do-gh-task` §1.4, `kp-do-gh-pr-loop`
§3, `kp-decompose-gh-task` §3, `kp-resolve-spec-decision` §4.3 and `kp-audit-alignment`
§7. Each runs this after
its own dedup finds no existing item and before `gh issue create`. When that dedup
instead reuses an item carrying `goal-ref:` outside the fence, the creator runs
*Repairing a reused goal question* below, then goes on with the reused item.

To raise an item, the creator first drafts it exactly as it always has — the **technical
item**: its type, title, body, marker lines, labels, assignee, priority and board add —
then reads the spec's domain layer for the fact the question turns on, and takes the
first branch that fits:

1. **No domain layer to read** — no spec behind the item, or its docs are not readable
   from this checkout → create the technical item.
2. **The missing fact is technical** — a library capability, a portal limit, how existing
   code behaves → create the technical item.
3. **The domain layer determines the answer** → create the technical item, with its
   Recommendation quoting the deciding domain phrase and naming its section, at
   `confidence: high`: it is creator-decided (§ *Human-gated item body* → *Confidence and
   creator-decided items*), and `kp-resolve-spec-decision` amends the spec when it
   resolves it.
4. **The domain layer is silent on the business or domain goal that settles it** → take
   the goal's `goal-ref: <key>` (§ *Goal questions*) and search for it in each of the
   **routed repos**. These are `<repo>`, the repo the item is created in, plus the target
   repo and every `requirementRepos` repo in `.claude/spec-sync.json`: the repos
   `kp-sync-spec-tasks` §0.5 files one spec's items in, each counted once. Search each one:
   `~/.claude/skills/kp-gh-lib/scripts/find-marker.sh <routed-repo> goal-ref <key>`. One spec's goal is
   then asked once, whichever repo its items land in. A config with no `requirementRepos`
   whose target repo is `<repo>` makes this the single `<repo>` search it always was.
   - **An open item already asks it** → call it `<goal>`: `#m` when it is in `<repo>`,
     `<owner>/<repo>#m` when it is in another routed repo, and when several ask it, the
     one in `<repo>`, else the first by repo then number. Create the technical item with
     `blocked-by: <goal>` beside its marker lines, once § *Milestone sequencing* (its
     acyclicity walk and edge rules) keeps the edge. Right after create, post `Waiting on
     goal question <goal>: <missing fact>.`, a blank line, and
     `<!-- kp-resolve-spec-decision-auto:waiting-on-goal -->`,
     so the goal's restore clears the edge in whichever routed repo holds it, exactly as
     it clears one `kp-resolve-spec-decision-auto` §4.0 wrote. A dropped edge gets
     neither the line nor the comment, and the run reports why.
   - **None does** → create the goal question below in place of the technical item.

**Creating the goal question.** It takes the § *Goal questions* shape: label
`type:question`; the title is the technical title's `[<REPO-CODE>] ` prefix plus the
domain question; the technical item's marker lines, unchanged, with `goal-ref: <key>`
beside them; the domain question(s) and "## What this settles"; "## To resolve" with the
technical item's pasteable prompts; and in `<details>` the technical question(s) in short
form with their evidence. Every other label, the assignee, the priority and the board add
stay the technical item's. Write the technical body to `/tmp/technical.md` and the goal
body to `/tmp/goal.md`, both with `__ISSUE__` where the number goes. In the command,
write a `'` inside a substituted value as `'\''`.

**Create — one call:** `~/.claude/skills/kp-gh-lib/scripts/goal-question.sh create
--repo <repo> --technical-body-file /tmp/technical.md --technical-title '<technical
title>' --technical-type <technical type> --goal-body-file /tmp/goal.md --goal-title
'<goal title>' --goal-ref '<key>' --missing-fact '<missing fact>' --creator <creator>
--label <l>…`, with every other label of the technical item as a `--label`, plus the
creator's `--project`, `--priority top`, `--assign-owner`, `--origin` and `--parent`. It
creates the item through `create-item.sh`, which substitutes the number into the goal
body and adds, assigns, prioritises and places it, then records the restore source at
once: the escalation comment `kp-resolve-spec-decision` restores from, in
`kp-resolve-spec-decision-auto` §4.0's shape — the technical title and body (number
substituted) verbatim in a backtick fence one longer than the body's longest backtick
run, under `**Raised as a goal question (agent, via /<creator>).** The spec does not say
<missing fact>.`, `goal-ref: <key>` and a `restore-type: <technical type>` line naming
the label the restore puts back. A goal question never exists without its restore
source, so when that comment fails it puts the technical title, body and label back and
exits `3`: report both the failure and the revert. Its JSON carries the issue number;
`create-item.sh`'s best-effort skips land in its `skipped` and are reported, never fatal.

**Repairing a reused goal question.** A reused item that carries `goal-ref:` outside the
fence but has no `<!-- kp-resolve-spec-decision-auto:escalated -->` comment — a `create`
call that stopped between create and comment — is put back to the technical item, the
revert `create` makes when its comment fails: draft the technical item again with
`__ISSUE__` the reused item's number, then `gh issue edit <n> -R <repo> --title
'<technical title>' --body-file /tmp/technical-final.md`, adding `--remove-label
type:question --add-label <technical type>` when the technical type is not
`type:question`, and report it. One that has the comment needs nothing.

Nothing downstream changes. The creator's dedup finds the goal question by the markers it
kept, so a re-run creates no sibling, and a skill parks on it through the same `blocks:`
edge. `kp-resolve-spec-decision` handles it as any goal question: it records the goal,
then restores the technical title and body, and the type the creator drafted from the
comment's `restore-type:` line.

## Creating an item (family convention)

The rules every item-creating skill shares — `kp-create-gh-item`, `kp-decompose-gh-task`,
`kp-sync-spec-tasks`, `kp-audit-alignment` §7, and a follow-up filed per § *Filing a
follow-up item*. A creator
points here and adds only what is specific to it. Edges follow § *Milestone sequencing*.
Every created item is placed per § *Milestone sequencing* → *Every new item has a
milestone*. `scripts/create-item.sh` implements these rules' mechanical chain — create,
`__ISSUE__` substitution, the operator ping for a human-gated type (§ *Operator
notifications*), assignee, board add, Priority, Status, placement and sub-issue
link — in one call (`kp-gh-lib/SKILL.md` § *`create-item.sh`*); a creator calls it rather
than running the steps itself.

### Model-tier rubric

Every `type:coding` item gets exactly one `model:*` label recommending which model
`kp-do-gh-task` should run it with. The label is `model:<model>` or
`model:<model>-<effort>`, where `<model>` is `opus`, `sonnet` or `haiku` and `<effort>`
is one of `low`, `medium`, `high`, `xhigh`, `max`; a label without an effort runs at the
CLI's default effort. The label is **advisory**: `kp-do-gh-task` reads it,
reports it, and surfaces a mismatch with the running model, but a session cannot switch
its own model or effort mid-run. Human-gated (`type:decision` / `question` / `conflict` /
`research`) and `type:epic` items get **no** `model:*` label.

The launchers apply the tier when they start a child: `kp-do-gh-task-loop` starts the
build child, and `kp-gh-lib/scripts/pr-loop.sh` the fix and escalate children, at the
labelled model and effort. `pr-loop.sh` starts the review child at the labelled model
and effort too, but never below `high`: a `low` or `medium` effort is raised to `high`
for the review. A label without an effort passes no `--effort`, so its
review runs at the CLI's default effort.

**Opus is the default. Reach up to `model:opus-xhigh` when a subtle miss is costly and
hard to see in review, and down to haiku only when the work clearly belongs there;
sonnet is not recommended (see § *Model-tier evidence*).**

Tiers assigned to new items:

- **`model:opus`** — the **default**, at the CLI's default effort: anything with real
  complexity, cross-cutting reach, risk, OR any interpretive judgement — perf/CWV
  budgets, accessibility conformance, architecture-touching, multi-file orchestration,
  anything where a miss is costly, or any spec that needs careful reading. When unsure
  whether work is "standard", it is opus.
- **`model:opus-xhigh`** — when a subtle miss is costly and hard to see in review:
  security-sensitive code (authentication, authorisation, secrets, input handling at a
  trust boundary), concurrency or locking, data migrations and irreversible writes, a
  change to a contract other services or skills depend on, or an item whose acceptance
  criteria cannot all be proven by an automated test.
- **`model:haiku`** — ONLY truly mechanical, zero-ambiguity, tiny surface: a single
  config value / constant, a copy tweak, a doc-only change or slice, an obvious one-line
  utility. If it is bigger than that, it is not haiku.

Tiers **not assigned** to new items — valid when the operator sets one by hand, and
kept so existing items stay valid, but never chosen by a creator until § *Model-tier
evidence* has numbers for them:

- **`model:sonnet`** — measured on a private backend project it cost more tokens and turns than opus
  and saved nothing at list price (§ *Model-tier evidence*).
- **`model:opus-medium`**, **`model:opus-low`**, **`model:opus-high`**,
  **`model:opus-max`**, and every `model:sonnet-<effort>` and `model:haiku-<effort>`
  tier — no measurements yet.

When uncertain at a tier boundary — not just on an exact tie — always pick the larger
model and say why in the run's report. Between `model:opus` and `model:opus-xhigh`,
uncertainty picks `model:opus-xhigh`.

### Model-tier evidence

Measured for #100 on the 31 items of a private backend project merged 2026-09-16..18 (all
built on the model their label named), recomputed from session transcripts counting
each `message.id` once, since every posted row predates the #133 fix. A run is found by
its launch command. **Turns**, **output** and **total** are build + review summed over
all rounds; **peak** is the largest per-run context (input + cache write + cache read in
one request). `kp-fix-pr` runs and subagent transcripts are left out. Lines are
additions + deletions. Item numbers are that private project's issues, except #82, #92, #100, #133
and #142, which are kp-skills.

| item | tier | files | lines | rounds | turns | peak | output | total | build | review |
|---|---|---|---|---|---|---|---|---|---|---|
| #271 | haiku | 1 | 5 | 3 | 85 | 74k | 26k | 4.8M | 1.3M | 3.5M |
| #303 | sonnet | 6 | 71 | 1 | 91 | 105k | 31k | 7.3M | 2.8M | 4.6M |
| #295 | sonnet | 2 | 129 | 2 | 194 | 117k | 98k | 16.1M | 8.4M | 7.7M |
| #161 | sonnet | 8 | 296 | 1 | 102 | 107k | 42k | 8.8M | 5.2M | 3.7M |
| #160 | sonnet | 14 | 739 | 1 | 177 | 118k | 78k | 14.9M | 11.4M | 3.5M |
| #152 | sonnet | 8 | 431 | 1 | 168 | 117k | 75k | 12.9M | 9.5M | 3.5M |
| #270 | sonnet | 8 | 339 | 1 | 201 | 117k | 102k | 15.6M | 9.7M | 5.9M |
| #217 | sonnet | 6 | 308 | 1 | 128 | 117k | 76k | 10.5M | 7.4M | 3.1M |
| #171 | opus | 17 | 925 | 2 | 137 | 117k | 96k | 9.9M | 7.3M | 2.6M |
| #281 | opus | 18 | 391 | 2 | 81 | 115k | 54k | 5.7M | 2.8M | 2.9M |
| #169 | opus | 9 | 614 | 1 | 54 | 108k | 44k | 3.5M | 2.4M | 1.1M |
| #166 | opus | 11 | 364 | 1 | 115 | 116k | 77k | 9.2M | 7.4M | 1.7M |
| #163 | opus | 6 | 304 | 1 | 99 | 116k | 66k | 6.7M | 3.5M | 3.1M |
| #157 | opus | 7 | 384 | 1 | 46 | 116k | 31k | 3.1M | 2.4M | 0.7M |
| #170 | opus | 15 | 567 | 1 | 40 | 101k | 30k | 2.8M | 1.9M | 0.9M |
| #165 | opus | 9 | 616 | 1 | 46 | 113k | 37k | 3.3M | 2.2M | 1.1M |
| #162 | opus | 8 | 608 | 1 | 72 | 115k | 50k | 4.8M | 3.2M | 1.5M |
| #156 | opus | 13 | 434 | 1 | 62 | 105k | 47k | 4.1M | 2.5M | 1.6M |
| #153 | opus | 18 | 810 | 1 | 107 | 115k | 77k | 8.1M | 5.6M | 2.5M |
| #168 | opus | 11 | 365 | 1 | 38 | 76k | 27k | 2.3M | 1.4M | 0.9M |
| #164 | opus | 7 | 247 | 1 | 40 | 84k | 23k | 2.4M | 1.7M | 0.8M |
| #155 | opus | 11 | 461 | 1 | 54 | 103k | 40k | 3.5M | 2.0M | 1.5M |
| #151 | opus | 6 | 528 | 1 | 34 | 100k | 31k | 2.3M | 1.6M | 0.6M |
| #232 | opus | 12 | 282 | 1 | 58 | 112k | 35k | 4.0M | 2.9M | 1.1M |
| #227 | opus | 20 | 732 | 1 | 117 | 116k | 86k | 9.3M | 7.5M | 1.8M |
| #23 | opus | 17 | 879 | 1 | 110 | 138k | 82k | 8.4M | 6.9M | 1.5M |
| #219 | opus | 7 | 646 | 1 | 67 | 114k | 52k | 4.7M | 3.6M | 1.1M |
| #218 | opus | 4 | 468 | 1 | 85 | 115k | 57k | 5.1M | 4.1M | 1.1M |
| #70 | opus | 39 | 2054 | 2 | 269 | 116k | 181k | 19.9M | 17.1M | 2.8M |
| #69 | opus | 36 | 3316 | 2 | 289 | 192k | 243k | 23.7M | 20.6M | 3.1M |
| #72 | opus | 18 | 1386 | 1 | 114 | 117k | 132k | 7.9M | 6.5M | 1.3M |

Medians, sonnet (n=7) vs opus (n=23): total 12.9M vs 4.8M, turns 168 vs 72, output 76k
vs 52k, peak 117k vs 115k; per line changed 33k vs 9k tokens; per acceptance criterion
1.85M vs 0.87M. At list API prices (cache reads are 93–96% of tokens) the median item
costs $4.42 on sonnet vs $5.22 on opus ($4.21 for the 17 opus items of 200–800 lines),
and $1.22 vs $0.99 per 100 lines.

**Conclusion.** Sonnet items cost about 2.7× the tokens of opus items per item and
about 3.7× per line. The cause is turns (about 2.3×) at a similar context per turn, not
a bigger context. **Confidence: high** for tokens and turns in this repo and period;
**medium–low** that sonnet saves no money: at list price it breaks even per item and costs
more per line, and subscription usage limits weight models by an unpublished ratio.

**Confounders.** Only 7 sonnet items and 1 haiku item. Selection: sonnet got the items
judged "standard", which should favour it, and its diffs are smaller. The review runs on
the item's tier too, so review cost is not separated from build cost. All items but #303
and #295 were built before #92, all before #133, and all but #303, #295 and #171 before
the item contract lint (#82). Fix runs (up to 5.4M on #69, 3.2M on #295) and subagent
tokens (up to 3.5M) are excluded. The rubric change this suggests was decided in #142: sonnet is no longer assigned to
new items.
Effort tiers have no measurements yet; the `effort` column of the token-usage report
(§ *Token-usage report*, written by `report-tokens.sh`) is the source for them.

### Labels

Every created item carries exactly one `type:` label. Create any missing label before
use, with the family's colors, so the board reads the same in every repo — one call with
every label the item will carry:

```
~/.claude/skills/kp-gh-lib/scripts/ensure-labels.sh --repo <repo> type:coding model:opus repo:<name>
```

Its built-in map is the family's color list (`kp-gh-lib/SKILL.md`
§ *`scripts/ensure-labels.sh`*): every `type:*` label the family uses, `needs-contract`,
the three model labels and their effort tiers, and any `repo:*`. A label the map lacks takes its color as a
suffix, `<label>=<hex>`, from the creator's config or taxonomy; without one the script
exits 2 and creates nothing.

### Repo identification

The board is typically shared across repos (the operator's standing board, e.g.
**"Shop"**), so every created issue — epics and a bootstrap issue included,
milestone epics excepted (below) — is repo-identifiable at a glance by both:

- **Title prefix** `[<REPO-CODE>] `, the code of the repo the item is created in.
  Resolve it in order: config `repoCodes["<owner/name>"]` in `.claude/spec-sync.json` →
  the prefix already in use on the repo's own `repo:<name>`-labelled issues, read over
  REST (never the board) → derive from the repo name (drop the owner and any org-wide
  name prefix, uppercase the rest: `my-org/shop-data-api` → `DATA-API`).
  `kp-gh-lib/scripts/repo-code.sh <owner/name>` implements this order and prints the code
  with the label. Codes are stable — never change one once board items carry it.
- **Repo label** `repo:<repo-name>` (name without owner), created before first use
  (§ *Labels*).

**A milestone epic is repo-neutral.** A milestone epic is a `type:epic` issue that groups
one roadmap milestone, marked `spec-ref: milestone:<id>`. Its children can sit in several
repos, so its title gets **no** `[<REPO-CODE>] ` prefix and it gets **no** `repo:*`
label — even when every child is in one repo — and neither is ever added to an existing
one. Every other item keeps both, including an epic that is not a milestone epic. A
milestone epic's children take their code and label from the repo they are created in;
they inherit nothing from it. Which repo a milestone epic is filed in does not change.

Dedup is unaffected: `spec-ref` lives in the body, never in the title.

### Atomicity bar

A coding item, or a slice of one, is valid only if it is:

- **(a) independently shippable** — completable as one self-contained `kp-do-gh-task`
  PR, not requiring a sibling's unmerged branch;
- **(b) independently verifiable** — it carries its own concrete acceptance criteria
  **plus the cross-cutting gates that apply to it** (accessibility / performance /
  security per the spec), so `kp-do-gh-task`'s verification loop can prove it done in
  isolation;
- **(c) minimal scope** — the smallest coherent unit that still satisfies (a) and (b).

Make items as atomic as is sensible — no smaller, no larger. A seam that cannot carry its
own acceptance criteria is not an item: merge it, or route the ambiguity to a
human-gated item.

### Sub-issue linking

GitHub sub-issue tooling is inconsistent across `gh` versions and installs, so the
mechanism is **detected at runtime**. Try in this order and use the first that works:

1. **Native `gh` sub-issue support** — e.g. an `--parent` flag on `gh issue create`, or
   a `gh issue edit --add-sub-issue` style command. Probe with `gh issue create --help` /
   `gh issue edit --help` and grep for `sub-issue` / `parent`.
2. **`gh api` GraphQL `addSubIssue`** — the most portable programmatic path. Resolve
   both issues to node ids (`gh issue view <n> -R <repo> --json id -q .id`, or the REST
   `/repos/{owner}/{repo}/issues/{number}` `node_id`), each in the repo it was filed in:

   ```bash
   gh api graphql -f query='
     mutation($parent:ID!,$child:ID!){
       addSubIssue(input:{issueId:$parent, subIssueId:$child}){ clientMutationId }
     }' -F parent="$PARENT_NODE_ID" -F child="$CHILD_NODE_ID"
   ```
3. **The `gh-sub-issue` extension** (`gh extension list | grep sub`) — `gh sub-issue
   add`, only when already installed; never install it.
4. **Fallback: a task-list line** `- [ ] #<child>` in the parent's body (`gh issue edit
   <parent> --body-file …`), `- [ ] <owner>/<repo>#<child>` when the two are in
   different repos. **Check the parent body does not already contain the child's
   reference before appending**, so a re-run never stacks a duplicate line.

The native, GraphQL and extension paths are idempotent (re-linking an existing child is
a no-op). Report which mechanism was used.

`scripts/create-item.sh` links through the GraphQL path (2) only; a failed link is
recorded as `skipped: link`. Every other link, and a re-link after such a skip, runs
`~/.claude/skills/kp-gh-lib/scripts/link-item.sh`, which runs this full ladder and prints
the mechanism used as `via`.

### Picking the parent epic

A skill filing an item for a spec requirement picks its `type:epic` parent by
`epicMapping` in `.claude/spec-sync.json`. Whether a missing epic is created, and in
which repo, is the caller's rule.

**Doc or section epic (`per-doc` by default, `per-section` or an `overrides` entry when
configured).** Each spec doc (or top-level section) maps to one `type:epic` issue
carrying that doc's or section's `spec-ref`; each requirement's item is a child of it.

**Milestone table (`epicMapping.strategy: "milestone"` only).** Across the spec docs in
the run, find the one markdown table whose first header cell is `Milestone` and whose
first-column cells each start with an id `M<number>` (bold allowed, e.g.
`| **M5 — Scheduler, …** |`). A cell's text after the id and its dash, with bold markers
stripped and whitespace trimmed, is that milestone's title (`**M0 — Foundations**` →
`Foundations`). No table, or several, means no placement; the caller says what it does
then.

A row lists a ref when its cells contain `REQ-<AREA>-<nnn>`, slash shorthand included:
`REQ-CART-001/002/003` lists 001, 002 and 003. A ref listed in exactly one row is
**placed** in that row's milestone; one listed in no row or in several is **unplaced**
and gets no parent.

**Milestone strategy.** There is no doc or section epic — an item under one has no
milestone-epic ancestor, so milestone sequencing never sees it — so never look for or
create one. A new item for a ref placed in `M<n>` gets its parent in this order:
1. **The ref's sub-epic** — a `type:epic` issue already carrying the ref's `spec-ref`
   that `milestone-of.sh` places in `M<n>` or an earlier milestone. A sub-epic with no
   milestone, or a later one, does not qualify.
2. **Otherwise the milestone epic** keyed `spec-ref: milestone:M<n>`. Dedup it like any
   other epic, across repos: `~/.claude/skills/kp-gh-lib/scripts/find-marker.sh <repo>
   spec-ref milestone:M<n> --state all --label type:epic` in the target repo and every
   `requirementRepos` repo. One created when
   none exists is repo-neutral per § *Repo identification*, titled
   `Epic M<n> — <milestone title>`.

Until the item exists, its milestone is the milestone of the parent this picks: the
sub-epic's `milestone-of.sh` result when step 1 applies, which can be earlier than the
table's placement, else the placement.

### Pasteable-prompt `__ISSUE__` substitution

A human-gated item's "To resolve" carries a pasteable prompt naming the **created
issue's own number** — never a metavariable, never a bare command. The number does not
exist until `gh issue create` returns, so write the body to a file carrying the literal
token `__ISSUE__` where the number goes, then patch it in:

```bash
URL=$(gh issue create -R <repo> --title "…" --body-file /tmp/item.md …)
NUM=${URL##*/}
sed "s/__ISSUE__/$NUM/g" /tmp/item.md > /tmp/item-final.md
gh issue edit "$NUM" -R <repo> --body-file /tmp/item-final.md
```

Best-effort: if the edit fails, note that the resolution line still carries the token
and continue — never fail the run over it.

## Filing a follow-up item (family convention)

Covers every issue a run files that is **not** its skill's defined output: a code-repo
change a spec fold makes owed (`kp-resolve-spec-decision` §4.5), or work a review finding
pushes outside the PR's scope (`kp-fix-pr` §3). Such an item must look like every other
board item, so a build loop can run it without the run that filed it.

- **Dedup first.** `gh issue list -R <repo> --state open --search "<key title words>"`;
  reuse a match instead of filing a second item.
- **Labels.** Exactly one `type:` label. A `type:coding` item gets exactly one `model:*`
  label per § *Creating an item* → *Model-tier rubric*; a human-gated type gets none.
- **Repo identification.** The `[<REPO-CODE>] ` title prefix and `repo:<name>` label,
  per § *Creating an item* → *Repo identification*.
- **Body.** Starts with the family human-only fence (§ *Human-only fence*); Scope and Acceptance criteria are self-contained.
  When a spec requirement backs the work, `spec-ref: <key>` goes outside the fence.
- **A `type:coding` follow-up carries the contract.** Its body follows § *Coding item
  body*, with the goal line `serves: G-<n> via <owner/repo>#<originating item>`. `G-<n>`
  is copied from the originating item's `serves:` line; when that item has none, it comes
  from the `Serves:` line of the section its `spec-ref:` names. In a no-spec repo the
  line is left out, as that section allows. Before `gh issue create`, the draft goes
  through `scripts/lint-item.py` and then § *Cold-reader check*. A draft that still fails
  after two rounds, a `FAIL spec-gap`, or a check that could not run goes through
  § *Settling a failing draft*: it is filed complete, raised as one human-gated item, or
  left `unfiled:` — never labelled `needs-contract`. Re-labelling an **existing** item
  whose re-checked body fails (`kp-sync-spec-tasks` §5a, `kp-resolve-spec-decision` §4.8
  step 3) gives it the `needs-contract` label
  (`gh label create needs-contract -R <repo> --color D93F0B --force`) and one comment on
  the filed item, so the reason outlives the run: its first line is
  `<!-- kp-gh-lib:needs-contract -->`, followed by the remaining `FAIL` lines, the
  cold-reader gaps, or the check that could not run with its exit code, and a line naming
  the filing skill. The run report names it with the failing rules or gaps.
- **Dependencies are markers, never prose.** One `blocked-by:` line per blocker, outside
  the fence, each after the acyclicity walk (§ *Milestone sequencing* →
  *Acyclicity*). A `### Depends on` paragraph is invisible to every skill that reads edges.
  - **A blocker that is an unmerged PR closing no issue** is written
    `blocked-by: <owner>/<repo>#<pr>`. The dependent starts only once that PR is
    `MERGED`; it keeps waiting while the PR is open, and if the PR is closed unmerged
    (`kp-do-gh-ready-items` §2.2, `kp-do-gh-task-loop` §1.4.3). A PR has no milestone,
    so the edge is outside § *Milestone sequencing*. A PR that closes an issue is
    waited on through that issue.
- **Epic link = milestone.** Link it as a sub-issue of the **originating item's nearest
  `type:epic` ancestor** (the originating item is the one whose work created the
  obligation: the decision a fold resolves, the issue a fixed PR closes), with the
  mechanism detected at runtime per § *Creating an item* → *Sub-issue linking*. It then
  inherits that item's milestone
  (`scripts/milestone-of.sh`), and its own edges, and those of any existing item that
  will carry `blocked-by:` it, follow § *Milestone sequencing*. Place it by running
  `scripts/milestone-place.sh` per § *Milestone sequencing* → *Every new item has a
  milestone*, with the originating item as `--origin` and its nearest `type:epic`
  ancestor, when it has one and it is not a milestone epic, as `--parent`, and act on
  its output.
- **Board.** Create it with `scripts/create-item.sh` on the resolved project, with
  `--origin` and `--parent` as *Epic link = milestone* says; it adds the item to the
  board and does the placement and link in the same call.
- **Report.** The run's report names one outcome: the filed item (number, type,
  `model:*`, epic, milestone), the human-gated item raised in its place, or the
  `unfiled: check could not run — <title> (exit <code>)` line.

## Alignment audit (family convention)

`kp-audit-alignment` checks the built system against its spec from the code side: it
traces merged PRs to items and REQs with `scripts/trace-matrix.sh`, describes each unit's
code blind, compares that description with the unit's REQs, cross-cutting sections and
goal frame, and rolls the units up against the goals; the subagents due at each launch
point run together. A unit's description is cached between rounds: updated from the diff
when few of its files changed, and rebuilt in full at least every fifth build. Every finding is verified read-only
before it counts, and a confirmed one is filed as an ordinary item — § *Creating an
item*, on the spec checkout's board with Status Ready, deduplicated in the repo it is
filed in:

| kind | meaning | filed as |
|---|---|---|
| `missing` | the spec requires it; the code does not do it | `type:coding` in the owning code repo |
| `divergent` | both cover it and disagree | `type:coding` in the owning code repo |
| `extra` (remove) | the code does something the spec never asks for, and it should go | `type:coding` removal item in the owning code repo |
| `extra` (keep) | as above, but it is worth keeping | `type:decision` in the spec repo: should the spec say so? |
| `spec-stale` | the code is right; the spec text is out of date | `type:decision` in the spec repo: should the spec change? |
| `goal-risk` | the system as built threatens a goal's target, a quality priority or a non-goal | per § *Before raising a human-gated item* |

A finding's key is its REQ id, or its `G-<n>` when it names no REQ. A run groups its
confirmed findings by (filing repo, route, key) and files **one** item per group, listing
every finding in it with its evidence; each group's item is drafted by its own subagent.
Each group is deduplicated only against issues that existed before the run — every search runs before the first create. Each filed body
carries one `audit-finding: <kind> <key>` line per kind in its group, so a later audit
links it instead of filing it again, and a `spec-ref:` the family's readers resolve: the
REQ id, or for a goal-only group the goals section's key with `serves: G-<n>` — never
`spec-ref: G-<n>`. The run's report is a closed
`type:audit` issue in the spec repo carrying `audit-unit:`, `audit-shas:` and
`audit-filed:` lines.
Refuted findings are recorded in the report and held back next round while their code
and spec are unchanged.

## Milestone sequencing (family convention)

Covers every skill that writes a `blocked-by:` / `blocks:` edge — `kp-sync-spec-tasks` §5, `kp-backfill-contract` §1.4,
`kp-decompose-gh-task` §6, `kp-create-gh-item` §3, `kp-resolve-spec-decision` §4.3–§4.4 —
and both that launch work: `kp-do-gh-ready-items` §2–§3 and `kp-do-gh-task-loop` §1.4.
Milestones run strictly in order; these rules keep the dependency graph from fighting it.

### An item's milestone

- A **milestone epic** is a `type:epic` issue carrying `spec-ref: milestone:<id>` outside
  the human-only fence, with an id of the form `M<number>`.
- An item's milestone is the nearest milestone epic above it on its sub-issue parent
  chain — its parent, or an ancestor reached through sub-epics.
  `kp-gh-lib/scripts/milestone-of.sh <owner/repo> <n>` looks it up in 1 point. An item
  not created yet belongs to the milestone epic its creating skill files it under.
- **Milestones run in ascending numeric order of the id:** M0, M1, M2, …, M9, M10.
- **An item with no milestone-epic ancestor is outside these rules:** it is never gated,
  gates nothing, and its edges are written as before. An edge falls under the rules only
  when both of its ends have a milestone. An item linked to its epic only through the
  task-list fallback has no parent the lookup can see, so it has no milestone.

### Every new item has a milestone

- **The rule.** Every item a `kp-*` skill creates is placed with
  `kp-gh-lib/scripts/milestone-place.sh`, and the creating skill acts on its output after
  `gh issue create`. `link: "item"` → link the new item as a sub-issue of `epic` per
  § *Creating an item* → *Sub-issue linking*. `link: "<owner/repo#r>"` → link that chain
  root under `epic`; the new item keeps its own parent. `link: "none"` → nothing to link.
  With `milestone: null` the project uses no milestones and creation is unchanged.
- **Inputs.** `--project` is the project the skill resolved in its setup, as
  `<owner>/<number>`; a skill that resolved no project skips placement and reports
  `milestone: not checked (no project)`. `--repo` is the repo the item is filed in.
  `--origin` is the existing item whose work produced the new one; each creating skill
  names its own, and one with none omits it. `--parent` is the parent the skill links the
  item to, when any — never a milestone epic: `milestone-of.sh` reads only an item's
  ancestors, so the script would see a milestone epic as having no milestone and link it
  under another epic. An item whose parent would be a milestone epic omits `--parent`, is
  placed like any item without one, and takes the output's `epic` as its parent. The
  exception is a milestone epic the skill's own rule already chose as the parent: a
  milestone epic `kp-create-gh-item` creates in the same run (§1.4) for its children, the
  milestone table's epic (`kp-sync-spec-tasks` under `epicMapping.strategy: "milestone"`),
  or a placed ref's epic (`kp-resolve-spec-decision` §4.3). That item keeps its parent,
  is not passed to the script, and reports `milestone: M<k>` from that epic. `--cache` is `<scratchpad>/milestone-current-<owner>-<number>.json`
  in the session scratchpad directory: one session is one run, so a run looks the current
  milestone up at most once, and a headless child, being its own session, looks it up
  itself.
- **Why the later milestone.** An item with no placed parent never goes into a milestone
  earlier than the current one, so a follow-up of an item in a done milestone never
  reopens it. When every milestone is done, `--current` returns the latest, and a new item
  there makes it not done until the item closes and the milestone is audited again. That
  is intended: new work must sit in some milestone.
- **An item under a placed parent** keeps the parent's milestone, even an earlier one: a
  child belongs with its parent.
- **The chain root** is linked whatever its state, type or repo within the project. The
  re-parent happens only when a skill creates a child under a chain with no milestone; it
  is per-run behaviour, not a backfill.
- **Exempt:** milestone epics and `type:audit` issues are never passed to the script and
  stay as they are created. A `type:audit` report closed at creation would otherwise count
  as a milestone item closed after its own audit, and its milestone would never be done.
- **Failed link.** A task-list fallback link gives no milestone (§ *An item's milestone*).
  When native sub-issue linking fails, the run reports
  `no milestone — sub-issue link failed` for that item.
- **A failed placement.** When `milestone-place.sh` exits non-zero (1: a lookup failed;
  2: bad arguments), placement never stops the run. The item is created as it would be
  without the rule, nothing is linked, and the run reports
  `milestone: not checked (placement failed: <first stderr line>)` for it.
- **Report lines**, one per created item: `milestone: M<k>`,
  `milestone: none (project uses no milestones)`, `milestone: not checked (no project)`,
  `milestone: not checked (placement failed: <first stderr line>)`,
  `no milestone — sub-issue link failed`, or `exempt (milestone epic)` for a milestone
  epic itself; plus
  `placed <owner/repo#r> under M<k> (chain had no milestone)` for each chain-root link.
  They are separate lines, so none takes precedence over another.

### Acyclicity

`blocked-by:` / `blocks:` together define a single "must-complete-before" relation, and
its graph MUST stay acyclic (a hard invariant). Before writing `X blocked-by: Y`, walk the
existing `blocks` / `blocked-by` markers across the tracked issues and confirm no path
leads from `Y` back to `X`. If the edge would close a cycle, **do not write it** — drop
that `blocked-by:` line and report the offending pair as a cycle. A cycle the spec text
itself states is handled the same way and never becomes a `type:conflict`. Never point a
`blocked-by:` at the item itself, directly or transitively, and never both `resolves: #<n>`
and `blocked-by: #<n>` the same issue (a downstream item completes its decision, so the
decision cannot also block it). `kp-gh-lib/scripts/edge-check.sh` runs this walk — the
`cycle` verdict — so a skill calls it rather than walking the markers itself.

### Edges stay inside one milestone

Before writing `X blocked-by: Y`, and after the acyclicity walk, compare the milestones.
`blocks:` is the same relation seen from the blocker and follows the same rule.
`kp-gh-lib/scripts/edge-check.sh` makes this comparison too, returning `ok`, `drop-earlier`
or `pull-forward` (with the epic to pull into) for an edge it found acyclic.

- **Same milestone** → write the edge.
- **Y's milestone is earlier** → do not write it: the gate already finishes Y's milestone
  first. Report `dropped X blocked-by Y (M<j> runs before M<k>)`.
- **Y's milestone is later** → pull Y forward into X's milestone (below), then write the
  edge. X is never pushed to a later milestone.

### Pulling a prerequisite forward

1. **File the prerequisite under X's milestone epic.** One not created yet is created
   there. One that exists is re-parented to it —
   `addSubIssue(input:{issueId:<epic node id>, subIssueId:<item node id>, replaceParent:true})`,
   or, on the task-list fallback, its `- [ ] #<item>` line moves to the new epic's body.
2. **Mark it** outside the human-only fence with one line:
   `milestone: M<k> (spec: M<j>) — pulled forward, required by #<n>`. `spec:` names the
   milestone the spec plans; a skill with no spec to read writes `was:` and the milestone
   the item left. A later move rewrites this line in place, keeping the first `spec:` /
   `was:` value and appending each requiring item. A move never rewrites a dedup marker
   (`spec-ref:`, `slice:`, `parent:`).
3. **Re-apply the edge rules to the moved item**, transitively: a blocker of it still in
   a later milestone is pulled forward too; an edge onto it from an item left in a later
   milestone now points at an earlier milestone and is dropped.
4. **Report the move:** `moved <ref> M<j> → M<k>, required by <ref>`.

Spec docs are not edited, and no human-gated item is raised.

### Determinism

A re-run on unchanged input reaches the same board and changes nothing.

- **Moves only go earlier.** An item already in an earlier milestone than its spec plans
  stays there, even once what required it closes — nothing ever moves back.
- **The parent chain is the item's milestone**, not the spec's plan; the `milestone:`
  note only records why the two differ. A skill that repairs sub-issue links
  (`kp-sync-spec-tasks` §2.2) counts an item already under an earlier milestone epic than
  planned as linked, and never re-links it to the epic the spec maps it to.
- **Evaluate edges in a fixed order** — dependent, then blocker, each by repo then number
  (by `spec-ref` when untracked) — so the same moves happen in the same order.

### The whole-milestone gate

- **No item of milestone M<k> launches while any non-epic item of an earlier milestone is
  open** — coding and human-gated items alike. `kp-do-gh-ready-items` defers the item and
  `kp-do-gh-task-loop` stops on it; `--only` and `--order` never override the gate.
- `kp-gh-lib/scripts/milestone-gate.sh --project <owner/number> <owner/repo> <n>` decides
  it, per project: `waitingOn` names the earliest milestone still open and `openEarlier`
  its open items.
- `kp-gh-lib/scripts/milestone-gate.sh --project <owner/number> --current` looks up the
  project's **current milestone**: the earliest milestone that is not done by the gate's
  own test, or the latest one when every milestone is done (`null` when the project has
  no milestone epic).
- **Waiting needs no operator action**, so it is reported and never pings Telegram.
- **An edge from an earlier-milestone item onto a later-milestone item stalls both:** the
  earlier item waits on the later one, which waits on the gate. `milestone-gate.sh`
  returns each such edge it meets in `crossEdges`, and the orchestrator names it with the
  repair advice: `fix the edge: re-run /kp-sync-spec-tasks (it pulls the blocker forward into the dependent's milestone), or edit the marker to point at the same-or-earlier-milestone item the dependent actually needs`.
- **A milestone whose items are all closed is still not done until it is audited** —
  § *Audit gate* below.

### Audit gate

A milestone counts as done only once an alignment audit of it (§ *Alignment audit*) files
nothing, or the operator accepts what is still open, so drift is fixed before later
milestones build on it.

- **Done** means: every non-epic item under the milestone is closed, no `type:decision`
  carrying `audit-close: M<k>` is open, and either a `type:audit` issue carrying
  `audit-unit: milestone:M<k>` was created after the last of those items closed, or a
  closed `audit-close: M<k>` decision exists, whatever option resolved it.
  `milestone-gate.sh` searches both markers across the epic's owner (`user:` / `org:`),
  since an epic may live in a code repo while its audits live in the spec repo, and keeps
  only hits in repos linked to the project the run resolved, so two boards' M0…Mn never
  gate each other — one search per marker for every milestone, bucketed by the marker's
  `M<k>`, so a call costs three searches however many milestones exist. A spec repo
  holding audits must be linked to the project (`linkProjectV2ToRepository`), or the gate
  never sees its audits.
- **Gate fields.** `auditNeeded: "M<k>"` — every item is closed but there is no current
  audit (and no audit-close decision); `waitingOn` stays set. `auditRound` counts the
  `waitingOn` milestone's audit issues, and `lastAuditFiled` is the newest one's
  `audit-filed:` list (`[]` for `none`, `null` with no audit).
- **The spec repo** is the `--spec-repo` argument, then `specRepo` in the checkout's
  `.claude/spec-sync.json`, then the current checkout when it holds spec docs (config
  `specGlobs`, else `docs/specs/**/*.md`, `specs/**/*.md`, `SPEC*.md`) — never the epic's
  repo or an item's `spec:` lines. With none, launch nothing for that milestone and
  report `audit: no spec repo`.
- **Round cap first.** When the gate's `waitingOn` milestone has `auditRound` ≥ 6 and
  either a non-empty `lastAuditFiled` or `auditNeeded` set, never launch another audit
  for it. Instead raise the audit-close decision, once: search
  `~/.claude/skills/kp-gh-lib/scripts/find-marker.sh <spec-repo> audit-close M<k> --state
  all` — **any** match, open or
  closed, means it was already raised (a closed one answered A while its items are still
  open), so none is created. Otherwise file a `type:decision` in the spec repo per
  § *Human-gated item body* and § *Creating an item* (no `model:*` label, never
  creator-decided): title `Close M<k> with these findings still open?`, the `lastAuditFiled` items listed,
  options **A** — keep M<k> open until they are fixed — and **B** — move them to the next
  milestone and treat M<k> as audited, the `audit-close: M<k>` line outside the fence,
  and the resolution prompt `/kp-resolve-spec-decision <n> --repo <spec-repo>
  --spec-repo <spec-repo>` (the `__ISSUE__` substitution). The loop's outcome is
  `waiting-on-audit-close #<d>` (filing the decision pings the operator through
  `create-item.sh`; the loop sends no second message).
- **Audit round.** Otherwise, on `auditNeeded`, the loop runs the audit once per milestone
  per run:
  1. **Spec checkout** — the loop's checkout when its `origin` names the spec repo, else
     the sibling `<parent-dir>/<spec-repo-name>`, cloned with `gh repo clone` when
     missing.
  2. **Launch and wait** with `kp-gh-lib/scripts/run-child.sh --log
     <scratchpad>/audit-<spec-repo-name>-M<k>.log --cwd <spec checkout> -- "/kp-audit-alignment
     --spec-repo <spec-repo> --milestone M<k> [--repo <R> --code-root <checkout>]"`,
     passing `--repo` / `--code-root` when the loop's checkout is a code repo `R`, then
     `--wait` in the foreground until it finishes. A `capacity=` hit is the loop's
     `capacity-limit` outcome.
  3. **Read the gate again.** Open → carry on and launch. `waitingOn` with open items
     (the audit filed work into M<k>) → `waiting-on-milestone M<k>`; the next time they
     are all closed a new round runs, rebuilding only the units that changed. Still
     `auditNeeded` → step 4.
  4. **Confirm before failing.** The gate sees the new audit only through the search
     index, which can lag a new issue by up to a minute. List the newest audits without
     search — `gh issue list -R <spec-repo> --label type:audit --state closed --limit 5
     --json number,createdAt,body` — and look for one whose `audit-unit: milestone:M<k>`
     line sits outside the human-only fence and which was created after step 2's
     launch. If there is one, wait in the foreground (`for _ in 1 2 3 4 5 6; do sleep 10;
     done` — the loop form, since a bare `sleep` is refused) and read the gate once
     more, taking its result as step 3's. With no such audit, or still `auditNeeded`
     after that read → `audit-failed M<k>` with the log path, **→ notify**, and no
     second launch this run.
- **Resolving** the audit-close decision is `kp-resolve-spec-decision` § *Audit-close
  branch*: no spec PR, no downstream item. On A it only closes the decision; on B it
  re-parents each listed item to the next milestone's epic, files a closed `type:audit`
  issue `Audit M<k> <date>` carrying `audit-unit: milestone:M<k>` and the acceptance,
  then closes the decision. Option B runs as one `kp-gh-lib/scripts/audit-close-move.sh`
  call. `kp-resolve-spec-decision-auto` never decides one — option B is the operator's
  acceptance.
- **Milestone branch.** In a code repo, an item with a milestone builds against and
  merges into the integration branch `release/M<k>`; an item without one merges into the
  default branch. The first task build creates the branch lazily from the default-branch
  HEAD. A done milestone is merged by `kp-gh-lib/scripts/milestone-merge.sh` — the
  default branch synced into `release/M<k>`, a `release/M<k>` → default PR, its CI, a
  merge commit (never a squash: the per-task squash commits are what `trace-matrix.sh`
  maps to items), the branch deleted — and only then tagged. It runs at the same two
  events as the tag, just before it. Spec repos never carry a `release/*` branch, so
  they report `no-branch`.
- **Milestone tag.** A done milestone carries a lightweight `milestone/M<k>` git tag on
  `origin`'s default-branch HEAD once its milestone branch has merged (the merge commit,
  in a repo that had one), in every linked repo holding one
  of its epics, an item under them, one of its audits or an audit-close decision for it
  (`milestone-gate.sh --milestone M<k>`'s `repos`). `kp-gh-lib/scripts/milestone-tag.sh`
  creates it, called by the two events that close a milestone: `kp-audit-alignment` §8
  after a `--milestone` audit files its report, and `kp-resolve-spec-decision`
  § *Audit-close branch* option B after it closes the decision, each only after
  `milestone-merge.sh` exits `0` — a failed merge skips the tag. It tags nothing while
  the milestone is not done, never moves an existing tag, and is idempotent, so a re-run
  tags only the repos an earlier one missed. A failure is report-only: it never fails the
  run that called it.

### Milestone branch

- **The rule.** An item whose `milestone-of.sh` lookup finds milestone `M<k>` builds on
  and merges into `release/M<k>`; an item with no milestone builds on and merges into the
  default branch. There is no config flag: a project that uses milestones gets the
  branches. `kp-gh-lib/scripts/milestone-branch.sh <owner/repo> <n> [--create]` resolves
  it (`kp-gh-lib/SKILL.md` § *`scripts/milestone-branch.sh`*).
- **Lazy creation.** `kp-do-gh-task` §1.1 runs it with `--create`, so the milestone's
  first task build creates `release/M<k>` at the default-branch HEAD; every later build
  in that milestone reuses it. §3.1 then fetches it and passes `--base origin/release/M<k>`
  to `worktree.sh`, opens the PR against it, and records `base:` in the run state. An
  explicit `--base` still wins.
- **Earlier-unmerged guard.** Creating `release/M<k>` while an earlier `release/M<j>`
  (j < k) still exists would start a milestone before the previous one reached the
  default branch, so `milestone-branch.sh` creates nothing and exits `3` with
  `earlier-unmerged release/M<j>`. `kp-do-gh-task` stops, reports it and pings the
  operator.
- **Closing on merge.** GitHub's closing keyword closes an issue only when its PR merges
  into the default branch, so a PR merged into `release/M<k>` leaves its issue open.
  `kp-review-gh-pr` §5.2 and the pr-loop close-out (`kp-do-gh-pr-loop` §2.6,
  `pr-loop.sh`) therefore close a still-open linked issue explicitly after the merge.
- **Orchestrators pass no `--base`.** `kp-do-gh-task-loop` and `kp-do-gh-ready-items`
  launch `kp-do-gh-task` without one; the child resolves the branch itself.
- **`closingIssuesReferences` on a non-default base is empty.** Verified 2026-11-08 on
  throwaway PR #347 (base `throwaway/341-base`, body `Closes #341`): the field stayed
  empty. So `preamble.sh --pr` falls back to the first closing keyword (`close[sd]`,
  `fix(e[sd])`, `resolve[sd]` + `#<n>`) in the PR body when the field is empty.

## Operator notifications (family convention)

The `kp-*` skills message the operator on Telegram through
`~/.claude/skills/kp-msg-me/scripts/send.sh` only when the operator is needed or a
session they launched has finished — never because an item merged or closed:

1. **A human-gated item is filed** — `type:decision`, `type:question` or
   `type:conflict`. `scripts/create-item.sh` pings on the create and `goal-question.sh
   escalate` on a fresh escalation, so no skill sends its own message for it, and no
   orchestrator re-pings a decision that already blocks an item. One exception is a
   creator-decided item (§ *Human-gated item body* → *Confidence and creator-decided
   items*) whose decision comment posted and that landed Ready: nothing pings at filing,
   and `kp-do-gh-ready-items` §1.8 pings instead when its resolve fails or finds no spec
   repo. The other exception is the wait-mode ping: `kp-do-gh-ready-items` sends one
   wait-mode ping per pass (§3.4) listing the unanswered human-gated items it is waiting
   on.
2. **Another stop needs the operator** — a dependency they must land, a stalling
   cross-milestone edge, a failed build, no usable checkout, a failed audit round. The
   orchestrator that hits it pings at once (its **→ notify** tags) and carries on.
3. **A top-level orchestrator session ends** — `kp-do-gh-ready-items`,
   `kp-do-gh-task-loop`, `kp-do-gh-pr-loop` and `kp-do-gh-pr-loop-all` send one wrap-up
   with `send.sh --session-end "<one line>"`. `scripts/run-child.sh` launches every child
   with `KP_HEADLESS_CHILD=1`, and with it set `--session-end` sends nothing, so only the
   session the operator launched reports its end; a usage-limit hit is named in that
   wrap-up with its reset time.

Nothing else pings: not a merge, a closed or skipped item, a PR closed or turned draft,
waiting on an earlier milestone, or ordinary progress. A failed send is noted once in
the report and never aborts a run.

## Token-usage report

`kp-gh-lib/scripts/report-tokens.sh` records each skill run's token cost in one
marker-tagged comment on the item or PR, **one row per run**, so a re-run never erases
an earlier run's figures:

```
<!-- kp-<skill>:token-usage -->

**Token usage — one row per run.** Format: `kp-gh-lib/NOTES.md` § *Token-usage report*.

| run start (UTC) | model | effort | input | output | cache write | cache read | subagents | total |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-09-10T10:00:00.000Z | claude-opus-5 | high | 22 | 34 | 460 | 5,800 | 1,090 | 6,316 |
| **Sum** (1 run) |  |  | 22 | 34 | 460 | 5,800 | 1,090 | 6,316 |
```

- **Keyed by run start.** A run whose start is already in the table rewrites its own
  row in place; any other run appends one. The `**Sum**` row totals every numeric cell.
- **model** is every model the run's top-level turns report, `+`-joined when there are
  several.
- **effort** is the launch effort from the environment variable `KP_EFFORT` when it is
  exactly one of `low`, `medium`, `high`, `xhigh`, `max` (case-sensitive); otherwise `—`.
- **subagents** is one number: the four figures summed over every assistant line since
  the run start in each `agent-*.jsonl` under `<transcript without .jsonl>/subagents/`,
  each `message.id` counted once per file (other files there, such as
  `agent-*.meta.json`, are ignored). No such directory → `0`; no readable transcript →
  `?`. It is how a skill's subagents — and a `context: fork` skill's turns — show up.
- **total** is the four top-level figures only; it **excludes `subagents`**, so rows
  written before that column existed stay comparable.
- **Output tokens are the cost signal.** Cache reads were 93–96% of every total measured,
  so compare runs on `output`, not `total`.
- **Capped at 100 rows**, oldest dropped first; the sum label counts them
  (`**Sum** (100 runs; 3 oldest rows dropped)`). That also keeps the body far under
  GitHub's 65,536-character comment limit.
- **Old comments convert in place.** A comment still in the pre-2026-09 single line
  (`**Token usage (this skill run)** — input: …`) becomes the table's first row, with
  run start, model, effort and subagents `?`. A table in the earlier 7-column format (no
  `effort`, no `subagents`) is converted the same way: each old row gets `?` in both new
  cells, and the Sum row is recomputed. A run with no readable transcript still gets its
  row, figures `?`, which the sum passes over; the script exits `0` either way.
- Each assistant transcript line carries an ISO-8601 UTC `timestamp` and a
  `message.usage` object; ISO-8601 UTC compares lexicographically, so a string `>=`
  against the run start selects exactly this run's turns. One model response spans
  several transcript lines (one per content block) that share `message.id` and repeat
  the same `usage`; the script counts each `message.id` once. A line with no
  `message.id` is always counted on its own.
- The markers belong to the calling skills (`<!-- kp-<skill>:token-usage -->`) and must
  not change — the script finds its comment by them. Nothing else parses these comments.
- Fixtures: `kp-gh-lib/tests/report-tokens/run.sh` drives the offline `--render` mode.
