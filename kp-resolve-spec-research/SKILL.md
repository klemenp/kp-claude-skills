---
name: kp-resolve-spec-research
description: Do one type:research issue's research — stop unless it is an open type:research item with no unanswered research gate decision, and stop before researching unless Chrome proves connected; a fresh read-only subagent researches it through the Claude-in-Chrome tools only, never WebSearch or WebFetch. When it concludes, post the findings as a marked decision-source comment, run /kp-resolve-spec-decision on the issue in a headless session (which drives its spec PR to merged), then drive each PR the research itself opened through a headless /kp-do-gh-pr-loop and every type:coding item that resolve created or reused through a headless /kp-do-gh-task-loop, one at a time; when only the operator can answer, raise one research gate type:decision item and stop, and on a re-run close a gate item answered by a person or by kp-resolve-spec-decision-auto and feed that answer back into the research. Runs interactively or as a headless claude -p --chrome child of kp-resolve-spec-decision-auto. Manual-only.
disable-model-invocation: true
argument-hint: [issue-number] [--repo <owner/name>] [--spec-repo <owner/name>] [--project <number|owner/number|id>]
allowed-tools: Read, Grep, Glob, Agent, Bash, mcp__claude-in-chrome__tabs_context_mcp
---

# Resolve a research item

Companion to `kp-resolve-spec-decision`. A `type:research` item is a spike: the spec
cannot be written until someone investigates. That skill resolves an item from a decision
someone already made; this one does the investigation first, for **exactly one**
`type:research` issue per run, and hands what it found to that skill.

This skill only **gates, researches, records and launches**. The research is done by a
fresh read-only subagent browsing through Chrome. The spec amendment, the downstream
items, closing the research item and driving the spec PR to merged are
`kp-resolve-spec-decision`'s, in its own headless session; building each resulting coding
item is `kp-do-gh-task-loop`'s, in its own.

**Where it runs.** The operator runs it interactively, and `kp-resolve-spec-decision-auto`
§4.2 launches it as a headless `claude -p` child after deciding one of its gate items.
The flow is the same in both.

**Chrome in a headless child.** A `claude -p` session gets the Claude-in-Chrome tools only
when launched with `--chrome`. Verified on Claude Code 2.1.269: a headless
`claude -p … --chrome` session listed 22 `mcp__claude-in-chrome__*` tools, a
`general-purpose` subagent it launched listed the same 22, and
`mcp__claude-in-chrome__tabs_context_mcp` answered; the same prompt without `--chrome`
had none. So every launcher passes `--chrome`, and an interactive session is started with
`claude --chrome` with the Claude in Chrome extension connected. Without it, the §3.2 Chrome
gate stops the run before the research writes anything. What `tabs_context_mcp` returns
with the extension disconnected is not verified, so that gate passes only on a result that
proves a live browser.

**Goal (success criteria):** the run ends in exactly one of: stopped at a §2 or §3.2 gate with its
reason; already answered by the operator; gate item raised; no-decision or resolve failed with a log; or
resolved — with the spec PR outcome and, for every item the resolve produced, its
task-loop outcome or the reason it was not run; or capacity-limit. A run that gets past
the resolver also carries, for every research PR (§6.1.1), its pr-loop outcome or why it
was not attempted. Every outcome is read from GitHub and is in the report.

## 1. Setup

1. **This run's arguments: `$ARGUMENTS` (empty if none). Parse them.** The first bare token is the research issue number `<n>`
   (required; if missing, stop and ask for one). Optional `--repo <owner/name>`,
   `--spec-repo <owner/name>` and `--project <number|owner/number|id>`.
2. **Resolve them once, here,** exactly as `kp-resolve-spec-decision` §1 does: target
   repo, spec repo, project (owner login and number), and config
   `.claude/spec-sync.json` (`repoCodes`, `labels`). Then
   `~/.claude/skills/kp-gh-lib/scripts/resolve-board.sh <owner> <number>` — 1 point — for
   the project node id and the highest `Priority` option, which §4 needs. `<project>` below
   is `<owner>/<number>`. Every headless child gets what it takes explicitly, because a
   headless child that has to ask simply stops.
3. **Where the children run.** Every child runs from the current directory. The resolver
   amends spec text only from a spec-repo checkout (its §1), and `kp-do-gh-task-loop`
   builds the repo of the checkout it runs in (its §0.2). If the current checkout is not
   the spec repo, say at the start that spec edits will be reported as not applied. If it
   is not the target repo (`gh repo view --json nameWithOwner`), §6.2 launches no
   task-loop.
4. **Log directory.** Create it once with `mktemp -d` and write its path out literally in
   every later call (shell variables do not persist between `Bash` calls).
5. **GitHub API budget.** The only Projects v2 calls are §1.2's board resolve, §2.2's
   `item-id.sh` read on a waiting gate item, and §4.1's `create-item.sh` (a 1-point
   board add, its lookups and the Priority edit), plus `research-prs.sh`'s 1-point board add per research PR (§6.1.1)
   — never `gh project field-list` or a board-wide
   `gh project item-list`. The children do their own board work. The rules are in
   `~/.claude/skills/kp-gh-lib/NOTES.md`.

## 2. Gate

Stop and report, **before any subagent launch or GitHub write**, at the first condition
that holds.

1. **Read the issue:** `gh issue view <n> -R <target-repo> --json
   number,title,body,labels,state,comments,url`.
   - **CLOSED** → stop: `research item closed`.
   - **No `type:research` label** → stop: `not a type:research item`.
2. **Find this item's gate items** — every issue §4 raised for `<n>`, in any state:

   ```bash
   ~/.claude/skills/kp-gh-lib/scripts/find-marker.sh <target-repo> \
     'kp-resolve-spec-research:gate research' '<target-repo>#<n>' --state all --comments
   ```

   then `gh issue view <m> -R <target-repo> --json number,title,state,labels,body,comments,url`
   for each issue it returns. A hit is a gate item when it is `where: "body"` — its body
   carries the line `<!-- kp-resolve-spec-research:gate research: <target-repo>#<n> -->` —
   or `where: "comment"` on its latest `<!-- kp-resolve-spec-decision-auto:escalated -->`
   comment (`commentId`) while its body carries `goal-ref:` outside the human-only fence:
   `kp-resolve-spec-decision-auto` §4.0 turned the gate item into a goal question, whose
   rewritten body drops the marker until `kp-resolve-spec-decision` restores it, and the
   escalated comment's verbatim block still carries it.
   - **An open gate item with no answer** (§4.3), or one carrying `goal-ref:` outside the
     fence — it waits on the operator's goal answer, not on this skill → stop:
     `waiting on gate item #m`, with its URL. Also report any §4.1 post-create step it
     still lacks, so the operator can repair it — a run that stops here never reaches
     §4.1's reuse. Both checks are reads: its body still carries `__ISSUE__`, or
     `~/.claude/skills/kp-gh-lib/scripts/item-id.sh <target-repo> <m> <project-id>` finds
     no board item.

The Chrome gate is §3.2, not here: only the research needs a browser, so a re-run that
§3.1 routes to "already answered" or straight to the resolver runs without one.

## 3. Research

### 3.1 Route

Find the research item's **latest decision comment**, recognised as §4.3 recognises one on
a gate item but from `decision-state.sh <target-repo> <n>`, plus this skill's findings
comment — the script's `findings`, never its `agent`, which may be a later
`kp-resolve-spec-decision-auto` comment. First match wins:

- **Latest is a person's** → outcome **already answered**. The operator decided the
  research item themselves; post nothing, launch nothing, and the report tells them to run
  `/kp-resolve-spec-decision <n>`.
- **Latest is this skill's findings comment** (`agent` is the `findings` comment) → a
  prior run concluded but its resolve did not close the issue. Do not research again; go
  to §5.2.
- **Otherwise** → §3.2.

### 3.2 Chrome is connected

Stop and report before §3.3's first GitHub write and the subagent launch. Call
`mcp__claude-in-chrome__tabs_context_mcp` with `createIfEmpty: true`, as the subagent's
first step does. Pass only when the result carries a tab id or a tab-group id. The tool is
not available, the call errors, or the result carries neither — including a bare "no tab
group" reply, which is not proven to differ from a disconnected extension's → stop:
`Chrome not connected — start the session with claude --chrome and the Claude in Chrome
extension connected`. There is no WebSearch or WebFetch fallback.

### 3.3 Close answered gate items

For each **open** gate item from §2.2, in ascending number — all of them have an answer
by now — close it, citing the answer and who decided it:

```bash
gh issue comment <m> -R <target-repo> --body-file "<logdir>/gate-closed-<m>.md"
gh issue close <m> -R <target-repo> --reason completed
```

The comment file holds `Answered by <a person|the agent, via
/kp-resolve-spec-decision-auto>: <the answer, with its expansion line when agent-decided>
— <decision-comment-url>. The research on <target-repo>#<n> resumes with this as settled
input.`, a blank line, and `<!-- kp-resolve-spec-research:gate-closed -->`. Skip the
comment when one carrying that marker is already newer than the answer (a re-run after a
failed close). The answer alone changes no spec text: it only feeds §3.4.

### 3.4 The subagent

**Settled answers** — for each **closed** gate item from §2.2 and §3.3, one line
`#<m> <title> — <the latest decision comment's answer> (a person|the agent)`, read per
§4.3, so a person's later comment on a closed gate item still supersedes the agent's; or
`none`.

Launch one `general-purpose` subagent with the Agent tool and `run_in_background: false`,
using the prompt below with `<target-repo>`, `<n>`, `<spec-repo>` and the settled answers
filled in. The call blocks until its result is back.

```
Research one GitHub research issue for the operator: <target-repo>#<n>.
Spec repo: <spec-repo>.
Settled answers from the operator's earlier gate questions — take them as given and
do not reopen them:
<settled answers>

You are read-only.
- GitHub and the repo: use gh issue view, gh pr view, GET-only gh api, Read, Grep and
  Glob. Never comment on, edit, label or close an issue or PR, never edit a file,
  commit or push.
- The web: browse only with the mcp__claude-in-chrome__* tools, never WebSearch or
  WebFetch. Start with mcp__claude-in-chrome__tabs_context_mcp (createIfEmpty: true)
  and work in your own tabs. Browsing is read-only: never sign in, submit a form,
  post, comment, buy, accept a dialog that changes anything, or change any setting on
  any site. A page behind a login is unreadable evidence, not a reason to sign in.
- Never copy cookies, tokens, session ids, account details or personal data from the
  browser into your reply. Cite a URL without any query parameter that carries a
  token or a session id.

1. Read the issue: gh issue view <n> -R <target-repo> --json title,body,comments.
   Skip everything from a "<!-- human-only:start" line to its "<!-- human-only:end -->"
   line. Read the spec text its spec-ref: lines point to, the spec's domain layer as
   ~/.claude/skills/kp-gh-lib/NOTES.md § "Decision layers" defines it, and the code,
   issues and PRs the issue cites.
2. Research what the issue asks, on the web and in the repo, until you can state a
   resolution or you know exactly what only the operator can tell you.
3. A question is the operator's only when it turns on a preference, a business
   priority, or a fact written nowhere you can read, and the spec's domain layer does
   not settle it. Anything else you settle from the evidence.
4. Reply with exactly one first line, then the rest:
   concluded: <the resolution, in one sentence>
   undecided: <what is still open, in one sentence>
   After "concluded:", give:
   - "## Resolution": what kp-resolve-spec-decision should do — the spec change and
     the downstream work it implies, or "no spec change: <why>", or "won't do: <why>";
   - "## Findings": what you found, in plain sentences;
   - "## Sources": every URL you used, spec section, file:line, issue and PR.
   After "undecided:", give:
   - "## Findings" so far and "## Sources", as above;
   - one to three operator questions written per ~/.claude/skills/kp-gh-lib/NOTES.md
     § "Human-gated item body": "## The question" (or "## Questions" with "### 1. …"),
     each with "## Why it matters", "## Options" of at least two lettered options
     described by their observable effect, and a Recommendation.
```

**Check the reply.** Its first line must be one of:

- `concluded: …` followed by "## Resolution" in one of its three forms, "## Findings" and
  "## Sources" → §5;
- `undecided: …` followed by "## Findings", "## Sources" and one to three questions, each
  with at least two lettered options → §4.

Anything else — no first line, a missing section, no options, more than three questions —
is handled as **undecided**, with the reason `subagent verdict unusable: <what>`. §4 then
raises the gate item with one question in place of the subagent's: *The research returned
no usable result — how should it continue?* — **A — Try again unchanged.** **B — Point it
somewhere** (reply with what to look at, or which source to trust). No recommendation;
the reason goes in `<details>`.

## 4. Undecided → raise a gate item, then stop

### 4.1 Create the gate item

Mechanics as for every created human-gated item:

- **Dedup.** `~/.claude/skills/kp-gh-lib/scripts/find-marker.sh <target-repo>
  'kp-resolve-spec-research:gate research' '<target-repo>#<n>'`, then `gh issue view <m>
  -R <target-repo> --json body,assignees,url` for a hit — §2.2 stopped on any open gate
  item it found, so a hit means search-index lag hid this one from §2.2. Reuse it: run
  each of those steps it still lacks — the substitution on its current body when that
  still carries `__ISSUE__`, the assignee when it has none, the board add when
  `item-id.sh` finds no board item, and Priority either way (setting it again is
  harmless) — then go to §4.2.
- **Title and body** per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Human-gated item body*:
  the question first, options described by their observable effect, the findings and
  sources inside `<details>`, and the self-check before create. The title carries the
  `[<REPO-CODE>] ` prefix, resolved as `kp-resolve-spec-decision` §4.3 does.
- **No climb.** The gate item skips that file's § *Before raising a human-gated item*: the
  subagent already read the domain layer (prompt step 1), and the answer must come back to
  this research, not go into a goal PR.
- **Never creator-decided.** The gate holds a question only the operator can answer, so
  its Recommendations are never `confidence: high` and the create never passes
  `--decided-body-file` (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Human-gated item body* → *Confidence and creator-decided items*).
- **Labels.** `type:decision`, `repo:<repo-name>` and config `labels.always`, each created
  with `gh label create -R <target-repo> … --force` when absent. No `model:*` label.

Write the body to `<logdir>/gate-<n>.md` with `__ISSUE__` where the gate item's own
number goes:

```
<!-- human-only:start (not LLM/spec context) -->
> **For humans:** <what the research is stuck on> — <what you need to decide>.
<!-- human-only:end -->

<every spec-ref: line of the research item, copied byte for byte>
blocks: <target-repo>#<n>
<!-- kp-resolve-spec-research:gate research: <target-repo>#<n> -->

<the question(s), each with Why it matters, Options and Recommendation>

## To resolve
Reply "A" / "B" here on #__ISSUE__ (or your own answer in a sentence), then run `/kp-resolve-spec-research <n>` — not `/kp-resolve-spec-decision`: the answer feeds the research on #<n>, which then resolves it.

<details><summary>Details for the resolving agent</summary>

Research gate item for <target-repo>#<n>.

<the subagent's first line, Findings and Sources — or the unusable-reply reason>
</details>
```

Then create it in one call, which substitutes the number, assigns it, puts it on the
board at top Priority and places it per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Every
new item has a milestone*, with the research item as `--origin`. The create carries one
`--label '<label>'` per config `labels.always` entry, none when it is unset:

```bash
~/.claude/skills/kp-gh-lib/scripts/create-item.sh --repo <target-repo> --title '<title>' --body-file "<logdir>/gate-<n>.md" --label type:decision --label 'repo:<repo-name>' --label '<labels.always entry>' --project <project> --priority top --assign-owner --origin <target-repo>#<n> --cache <scratchpad>/milestone-current-<owner>-<number>.json
```

Its JSON's `.number` is the gate item's number. Exit `1` means nothing was created: report
it and stop. Every later step is best-effort — the substitution, assignee (skipped on an
org-owned project), Priority (skipped when the board has none) and placement; note each
`skipped` entry, never fail the run over one. In a substituted value, write a `'` as
`'\''`. A gate item the dedup above reused keeps its parent and is not placed.

### 4.2 Point at it, then stop

On the research item, post once — unless a comment carrying the marker and naming #m is
already there — `Waiting on research gate decision #m.`, a blank line, and
`<!-- kp-resolve-spec-research:gate-pointer -->`. Launch nothing, report, and stop.

### 4.3 Reading a gate item's answer

The answer is the gate item's **latest decision comment**, read exactly as
`kp-resolve-spec-decision-auto` §2 reads one: classify the comments with
`~/.claude/skills/kp-gh-lib/scripts/decision-state.sh <target-repo> <m>`
(`kp-gh-lib/SKILL.md` § *`decision-state.sh`*), which leaves out skill output,
bot comments and everything before the latest
`<!-- kp-resolve-spec-decision:restored -->` comment. Exit `1` or `2` → report the
message and stop; a re-run reads it again.

- **agent-decided:** the script's `agent`;
- **a person's:** the script's `session`, or a `humanCandidates` entry that picks an
  outcome (`B`, `Option A — …`, `1B 2A`, a sentence answer). A candidate that only
  discusses or asks is not a decision.

The latest is the newest outcome-picking `humanCandidates` entry — every candidate
postdates `agent` and `session`, so a person's outcome-picking comment after an
agent-decided one supersedes it — else the one `latest` names. No decision comment → the
gate item has no answer.

## 5. Concluded → record, then resolve

### 5.1 Record the findings

Before anything is launched, so the record survives a failed resolve — and only when §3.1
did not route here, so a re-run never stacks a second one. Write the comment to
`<logdir>/findings-<n>.md` and post it with `gh issue comment <n> -R <target-repo>
--body-file "<logdir>/findings-<n>.md"`:

```
**Research concluded (agent, via /kp-resolve-spec-research):** <the concluded: sentence>

<the subagent's Resolution, Findings and Sources sections, verbatim>

An agent researched this in Chrome and concluded the resolution above; the operator did not pick it personally. To override it, comment your own decision and run `/kp-resolve-spec-decision <n>`.

<!-- decision-source: kp-resolve-spec-research -->
```

### 5.2 Run the resolver headless

`kp-resolve-spec-decision` is `disable-model-invocation`, so a headless `claude -p` child
runs it. It reads the findings comment as its decision (its §3 (c)), amends the spec,
reconciles referrers, creates or reuses the downstream items, closes the research item,
and drives the spec PR to merged through its own headless `kp-do-gh-pr-loop` — this skill
launches no pr-loop for that PR. Launch and wait on it with
`~/.claude/skills/kp-gh-lib/scripts/run-child.sh` — one launch call, then foreground
`--wait` calls (`Bash` `timeout: 540000`) re-issued until the child's result line
replaces `status: running`; never `run_in_background` or `Monitor`
(`~/.claude/skills/kp-gh-lib/NOTES.md` § *Waiting in a headless session*):

```bash
~/.claude/skills/kp-gh-lib/scripts/run-child.sh --log "<logdir>/resolve-<n>.log" --cwd "$PWD" \
  --timeout-min 240 \
  -- "/kp-resolve-spec-decision <n> --repo <target-repo> --spec-repo <spec-repo> --project <project>"
~/.claude/skills/kp-gh-lib/scripts/run-child.sh --wait "<logdir>/resolve-<n>.log"
```

The script owns the detached launch, the exit sentinel and the family's standard flag
set — `bypassPermissions` among them, required: the resolver edits issues, pushes, opens
a PR and launches the pr-loop with no human present. It needs no Chrome, so it gets no
`--chrome`. `--timeout-min 240` kills a resolver that overruns four hours; it ran
unbounded before.

**Capacity check**, before any GitHub read — the `capacity=` field of the `--wait` result
line, which also catches the pr-loop's limit line the resolver quotes. Anything but
`none` is a hit.

On a hit keep its `reset=` time and the CLI's limit line from the log; §6.1 still reads
the outcome, and §6.2 launches nothing.

## 6. Drive the resulting items

### 6.1 Outcome from GitHub, not the log

A non-zero child exit is not the outcome; GitHub state is.
`gh issue view <n> -R <target-repo> --json state,comments`:

- **OPEN**, carrying a `<!-- kp-resolve-spec-decision:no-decision -->` comment with no
  §3 decision comment newer than it (a `kp-resolve-spec-decision` §3 (a) or (c) source)
  → outcome **no-decision**, with the log path. No board call is made for it. Run
  §6.1.1, then report and stop.
- **OPEN** otherwise → outcome **resolve failed** (or **capacity-limit** on a §5.2 hit),
  with the log path. The findings comment stays, so a re-run goes straight to §5.2. Run
  §6.1.1, then report and stop.
- **CLOSED** → outcome **resolved**. From the resolver's latest `Resolved → …` or
  `Closed as won't-do …` comment take:
  - **the spec PR** (`…, PR <pr-url>`), classified as `kp-resolve-spec-decision-auto`
    §4.4 classifies one — merged, blocked on decision #d, parked, closed, or
    capacity-limit on a §5.2 hit — or `no spec change: <why>`;
  - **the resulting items:** the downstream item (`created|reused #<m>`) and every
    follow-up item the comment names. Items listed under `Re-pointed:` existed before and
    are not results. A won't-do resolve has none.

  Then §6.1.1, then §6.2.

#### 6.1.1 Drive the research PRs

A **research PR** is one opened for the research item itself rather than by a skill —
usually a live capture. The spec PR and the coding items' PRs have their own pr-loops and
are not research PRs. They run before §6.2 because a coding item may be `blocked-by:` one.

**The capture path.** When the operator chooses to capture in the interactive session
(e.g. a recorded fixture the research needs), that session — never the §3.4 subagent —
commits the redacted capture on a `research/<n>-<slug>` branch in a worktree at
`../<repo-name>-research-<n>`, and opens the PR in the target repo with a body of
`Refs #<n>.` and one `Redactions: <what was removed or replaced>` line, so the reviewer
can check them. `Refs`, never a closing keyword: the resolver closes the research item.
`research/`, never `task/`: `kp-review-gh-pr` and `kp-fix-pr` infer their linked item
from a `task/<n>-` branch, and the research item's criteria are not the capture's.
The PR is left to this step; nobody merges it by hand.

**Collect and board-add — one call.** The research PRs are the open PRs in the target repo
whose head branch starts with `research/<n>-` or whose body references `#<n>` (not
followed by a digit), leaving out any that closes another issue
(`Closes|Fixes|Resolves #<m>`, `<m>` ≠ `<n>`) — that one is its item's:

```bash
~/.claude/skills/kp-gh-lib/scripts/research-prs.sh <target-repo> <n> --project-id <project-id>
```

It adds each to the board (1 point each) and prints them ascending by number,
`[{"number", "url", "boardItem"}, …]` (`kp-gh-lib/SKILL.md` § *`research-prs.sh`*).
A `null` `boardItem` is a failed board add: note it, and the pr-loop still runs. Exit `1`
(the PR list failed) means no research PR was driven: report it and go on to §6.2.

For each entry, in the script's output order:

1. **Pr-loop** — not attempted when §5.2's capacity check hit, an earlier launch here
   hit, or §1.3 found the current checkout is not the target repo (the pr-loop runs from
   the PR's primary checkout); otherwise the same `run-child.sh` launch, foreground wait and capacity check as §6.2,
   with `/kp-do-gh-pr-loop <pr> --project <project>`, `<logdir>/pr-loop-<pr>.log` and
   `--timeout-min 240`. A
   hit stops all further launches, research PRs and coding items alike.
2. **Outcome from GitHub:** `gh pr view <pr> -R <target-repo> --json state` → `MERGED`
   is **merged**; still open is **PR open**, with the log path; or **capacity-limit**,
   or **not attempted** with why.

### 6.2 Run the task-loop on coding items

Read each resulting item: `gh issue view <m> -R <target-repo> --json
number,title,labels,state`. An item that is not `type:coding` (a new `type:decision`, a
`type:question`) is **not run** and is listed with its type. When the spec PR did not
merge, the coding items gated on it still go to the task-loop, which stops them on the
unmerged blocker and reports it.

Every `type:coding` item is **not attempted** when §5.2's or §6.1.1's capacity check hit, or when §1.3
found the current checkout is not the target repo — the report then gives
`/kp-do-gh-task-loop <m> --project <project>` to run from a target-repo checkout.
Otherwise run them **one at a time, in ascending number**, each only after the previous
child exited. `kp-do-gh-task-loop` is `disable-model-invocation`, so each is a headless
child; it picks the item's model and drives the item's PR through `kp-do-gh-pr-loop`.
Launch and wait on each with `run-child.sh`, as in §5.2:

```bash
~/.claude/skills/kp-gh-lib/scripts/run-child.sh --log "<logdir>/task-loop-<m>.log" --cwd "$PWD" \
  --timeout-min 600 -- "/kp-do-gh-task-loop <m> --project <project>"
~/.claude/skills/kp-gh-lib/scripts/run-child.sh --wait "<logdir>/task-loop-<m>.log"
```

then the capacity check on its result line's `capacity=` field. `--timeout-min 600` kills
a task-loop that overruns ten hours; it ran unbounded before. **A hit stops all further launches:** every remaining item is
**not attempted**, and the limit line goes into the report verbatim.

**Outcome from GitHub**, per item: `gh issue view <m> -R <target-repo> --json state`, and
its PR found as `kp-do-gh-task-loop` §1.2 finds one —

- item **CLOSED** with a merged PR → **merged**;
- an **open PR** → **PR open** (the pr-loop parked it or a decision blocks it), with the
  PR URL and the log path;
- **no PR** → **not built** (blocked on a dependency, a decision or a milestone, or the
  build failed), with the log path;
- capacity-limit on a hit.

## 7. Report

Print:

- the target repo, spec repo and project, and whether spec edits or task-loops were
  unavailable from this checkout (§1.3);
- **the research outcome:** stopped at a gate (the reason, and when a gate item is waiting,
  its URL and any post-create step it lacks); already answered, with
  `/kp-resolve-spec-decision <n>`; gate item raised, with its URL, its report line from
  NOTES § *Every new item has a milestone*, and the gate items this run closed; or
  concluded, with the findings comment URL;
- **the resolver outcome** — resolved, no-decision, resolve failed or capacity-limit — with its log
  path, and the spec PR outcome or `no spec change: <why>`;
- **every research PR** (§6.1.1), one line each: its URL and pr-loop outcome — merged,
  PR open with the log path, capacity-limit, or not attempted with why — or `no research
  PR`;
- **every resulting item:** its task-loop outcome and log path; or not run, with its type;
  or not attempted, with why;
- the **exact command to resume** each unfinished piece: `/kp-resolve-spec-research <n>`
  after a gate stop or a failed resolve; for a spec PR that did not merge,
  `/kp-resolve-spec-decision <n> --repo <target-repo>`, run from the spec-repo checkout;
  `/kp-do-gh-pr-loop <pr> --project <project>` for each research PR not merged;
  `/kp-do-gh-task-loop <m> --project <project>` for each coding item not merged;
- on a capacity-limit, the limit line quoted verbatim with its reset time, so a parent
  grepping this output sees it.

## Invariants

- **Gates before writes.** A closed or non-research item or an unanswered gate item stops
  the run before any subagent launch or GitHub write. A Chrome connection not proven by a
  tab or tab-group id stops a run that goes on to research, before its first GitHub write
  or subagent launch.
- **Research is read-only and Chrome-only.** One fresh subagent per run, never commenting,
  editing, committing or pushing, browsing only through `mcp__claude-in-chrome__*` — no
  WebSearch or WebFetch, no sign-in, no form submission. No cookie, token, session id or
  account data from the browser goes into a comment, a gate item or a log.
- **Never answer for the operator.** An undecided or unusable result becomes one gate
  `type:decision` item; its answer comes from a person or from
  `kp-resolve-spec-decision-auto`'s marked comment, and a person's later decision wins —
  on a gate item and on the research item alike.
- **Record before acting, once.** The findings comment is posted before the resolver
  launches and at most once per research round; a gate pointer and a gate close comment
  at most once each.
- **This skill resolves and builds nothing itself.** Spec edits, downstream items and the
  spec PR's pr-loop are `kp-resolve-spec-decision`'s; each coding item's build and PR are
  `kp-do-gh-task-loop`'s. The only pr-loops it launches are §6.1.1's, for research PRs.
- **No research PR left unattempted.** A run that reaches §6 never ends with a research
  PR it has not added to the board and driven through a pr-loop, or reported as not
  attempted with why.
- **Outcomes from GitHub, never from child logs or exit codes.** The only log read is the
  capacity check.
- **`bypassPermissions` only on the headless children this skill launches.**
- **One child at a time, and never end the turn while one is running:** a `run-child.sh`
  launch and its foreground `--wait`, never `run_in_background` or `Monitor`.
