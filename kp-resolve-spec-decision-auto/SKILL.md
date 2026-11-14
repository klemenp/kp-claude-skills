---
name: kp-resolve-spec-decision-auto
description: Work through every open type:decision issue in the target repo — for each, a fresh read-only subagent weighs the options independently and, when the requirement-level evidence settles nothing, climbs to the spec's domain goals; when one option is clearly best, post it as an agent-decided decision comment and run /kp-resolve-spec-decision on the issue in a headless session, which drives the spec PR it opens to merged via its own headless /kp-do-gh-pr-loop, then report each spec PR's outcome; when the answer turns on a domain goal the spec never states, rewrite the item in place as a type:question about that goal; skip a decision waiting on an unmet blocked-by, and leave anything else unclear to the operator. A kp-resolve-spec-research gate item is decided the same way, but resumes that research via a headless /kp-resolve-spec-research --chrome run instead of the resolver, its outcome read from GitHub, and an already-answered one is pointed at /kp-resolve-spec-research. Manual-only.
disable-model-invocation: true
context: fork
argument-hint: [--repo <owner/name>] [--spec-repo <owner/name>] [--project <number|owner/number|id>]
allowed-tools: Read, Grep, Glob, Agent, Bash, Bash(~/.claude/skills/kp-gh-lib/scripts/goal-question.sh:*)
---

# Resolve spec decisions automatically

Batch companion to `kp-resolve-spec-decision`. That skill resolves one decision from the
operator's own words; this one answers the open `type:decision` items **for** the
operator, but only where the answer is not really theirs to make — where one option is
clearly best on the evidence. Anything that turns on the operator's preference or on an
unwritten fact is first checked against the spec's domain goals (§3): a goal that settles
it decides it, a goal the spec never states turns the item into the operator's question
about that goal (§4.0), and anything else is skipped and stays on the board for them.

This skill only **selects, decides and launches**. Each decision is made by a fresh
subagent, recorded as a marked comment on the issue, and then carried out by a headless
`/kp-resolve-spec-decision` run — the spec amendment, downstream item, re-pointed
referrers, close, driving the spec PR to merged through its own headless
`/kp-do-gh-pr-loop` child, and syncing items to the merged text are all that skill's
work. This skill launches no pr-loop; it only reads the spec PR's outcome.

It is **`context: fork`**: the operator is never in the loop mid-run (anything unclear is
skipped and left on the board, never asked), so the batch runs in an isolated subagent
and only its §5 report returns to the session. A forked skill launching its own
foreground subagents (§3) and waiting in the foreground on a detached child (§4.2) were
both probed on Claude Code 2.1.270.

**Goal (success criteria):** every open `type:decision` item in the target repo ends
in exactly one of: resolved on an agent decision, escalated to a goal question, waiting
on #m, skipped with a reason, already answered by a person, resolve-failed with a log,
research resumed, research already answered, research already closed,
research-resume-failed with a log,
capacity-limit, or not attempted
after a capacity limit; every resolved item whose
resolve opened a spec PR also ends with one spec PR outcome, read once the resolver and
its pr-loop have exited — merged, blocked on a decision, parked, closed, or
capacity-limit — and each outcome is in the report.

## 0. Setup

1. **This run's arguments: `$ARGUMENTS` (empty if none). Parse them:** optional `--repo <owner/name>`, `--spec-repo <owner/name>`
   and `--project <number|owner/number|id>`.
2. **Resolve them once, here,** exactly as `kp-resolve-spec-decision` §1 does: target
   repo (`--repo` → config `.claude/spec-sync.json` `targetRepo` → stop), spec repo
   (`--spec-repo` → config `specRepo` → the current checkout when it holds spec docs →
   stop), project (`--project` → config `project` → stop). Each stop prints one line
   naming the flag and the candidates below it:
   - `no target repo given; pass --repo <owner/name>`, then `gh repo list <owner>`;
   - `no spec repo given; pass --spec-repo <owner/name>`, then `gh repo list <owner>`;
   - `no project given; pass --project <owner/number>`, then `gh project list --owner
     <repo-owner>` and `gh project list --owner @me`.

   Every child in §4 gets the ones it takes explicitly. Also resolve the **routed repos** §3 and §4.0 search for goal questions, per
   `~/.claude/skills/kp-gh-lib/NOTES.md` § *Before raising a human-gated item* branch 4,
   with `<target-repo>` as the item's repo.
3. **Where the children run.** Each child runs from the current directory, and the
   resolver amends spec text only from a local spec-repo checkout — so whenever it opens
   a spec PR, the pr-loop it launches runs in that PR's repo. If the current checkout is
   not the spec repo, say at the start that spec edits will be reported as not applied.
   A research child (§4.2) launches its resolver and `kp-do-gh-task-loop` children from
   that same directory, and runs no task-loop when it is not the target repo.
4. **Log directory.** Create it once with `mktemp -d` and write its path out literally
   in every later call (shell variables do not persist between `Bash` calls).
5. **GitHub API budget.** Nothing here touches Projects v2: no `gh project field-list`,
   no board-wide `gh project item-list`. Issue and PR reads only, plus §4.0's issue-side
   title, body, label and comment edits (its `milestone-of.sh` lookups read sub-issues,
   not the board) and §2's comment and close on a gate item whose research is closed;
   the resolver's pr-loop does its own board work in its own session.
   The rules are in `~/.claude/skills/kp-gh-lib/NOTES.md`.

## 1. Select the items

```bash
gh issue list -R <target-repo> --label type:decision --state open --limit 200 \
  --json number,title --jq 'sort_by(.number) | .[] | "\(.number)\t\(.title)"'
```

Only `type:decision`. `type:question`, `type:conflict` and `type:research` items are
never touched. No items → report "no open decision items" and stop. Exactly 200
returned → say in the report that more may exist for the next run.

**Research gate items.** A selected item whose body carries
`<!-- kp-resolve-spec-research:gate research: <repo>#<research-n> -->` was raised by
`kp-resolve-spec-research` §4: its answer feeds that research, not a spec amendment. §2,
§3 and §4.1 handle it as any other item, and a person's decision still wins. What differs
is §2's closed-research check and already-answered pointer, §4.1's override line, §4.2's
launch, §4.3's outcome and §5's report, each as that section says. `<research-n>` is the
number in the marker.

Work through the items **one at a time, in ascending number**: a resolver edits shared
`blocked-by:` markers and spec text, so a later decision must see what an earlier one
changed. §2–§4 finish for one item — including the resolver's pr-loop on its spec PR —
before the next starts.

## 2. Classify the item

`gh issue view <n> -R <target-repo> --json number,title,body,state`, then classify its
comments with `~/.claude/skills/kp-gh-lib/scripts/decision-state.sh <target-repo> <n>`
(`kp-gh-lib/SKILL.md` § *`decision-state.sh`*), which already leaves out skill
output, bot comments and everything before the latest
`<!-- kp-resolve-spec-decision:restored -->` comment. Exit `1` or `2` → note the item
**not classified** with the message and move on to the next item. A decision comment is
either:

- **agent-decided:** the script's `agent` — this skill's own, or the creating skill's
  posted at filing on a creator-decided item (`~/.claude/skills/kp-gh-lib/NOTES.md`
  § *Human-gated item body* → *Confidence and creator-decided items*);
- **a person's:** the script's `session` — a transcription of the operator's own words
  — or a `humanCandidates` entry that picks an outcome (`B`, `Option A — …`, `1B 2A`,
  "won't do", a sentence answer). A candidate that only discusses or asks is not a
  decision.

The **latest decision comment** is the newest outcome-picking `humanCandidates` entry
(every candidate postdates `agent` and `session`), else the one `latest` names.

Then, first match wins:

- **Body carries `audit-close: M<k>`** outside the human-only fence → an audit-close
  decision the task loops raised (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Milestone
  sequencing* → *Audit gate*). Accepting a milestone's open findings is the operator's
  call, so outcome **left to the operator**: no subagent runs and nothing is posted.
- **Body carries `goal-ref:`** outside the human-only fence → a prior run's §4.0
  rewrote the item but stopped before its label swap. Swap it only —
  `gh issue edit <n> -R <target-repo> --remove-label type:decision --add-label
  type:question` (create `type:question` with `gh label create` first if the repo lacks
  it); outcome **escalated → goal question**.
- **A research gate item whose research item is CLOSED** —
  `gh issue view <research-n> -R <target-repo> --json state,url` → its answer has nothing
  left to feed: `kp-resolve-spec-research` §2.1 stops on a closed research item, and
  `kp-resolve-spec-decision` never closes a gate item. Close it, whatever its comments
  hold:
  1. Write `Closed: research item <target-repo>#<research-n> is already closed, so this
     question no longer feeds any research. This run launched nothing.`, a blank line,
     and the `<!-- kp-resolve-spec-decision-auto:research-closed -->` marker to a file,
     and post it once:
     `~/.claude/skills/kp-gh-lib/scripts/comment-once.sh <target-repo> <n> --marker '<!-- kp-resolve-spec-decision-auto:research-closed -->' --body-file <file>`.
  2. `gh issue close <n> -R <target-repo> --reason "not planned"`. A re-run after a
     failed close skips step 1 — `comment-once.sh` then prints `exists` — and retries
     this.

  Outcome **research already closed**. No subagent runs and nothing is launched.
- **An unmet `blocked-by:`** — a marker line outside the fence names a blocker that is
  not done, judged as `kp-do-gh-ready-items` §2.2 judges one (in the blocker's own repo,
  an issue is done once `CLOSED`, a pull request only once `MERGED`) → outcome
  **waiting on #m**. No subagent runs and nothing is posted.
- **Latest is a person's** → outcome **already answered**. Post nothing and launch
  nothing; the report tells the operator to run `/kp-resolve-spec-decision <n>` — on a
  research gate item, `/kp-resolve-spec-research <research-n>`.
- **Latest is agent-decided** → an agent — a prior run of this skill, or the creator at
  filing — decided, but no resolve has closed the issue. Do not decide again; go to §4.2.
- **No decision comment** → §3.

## 3. Decide — one fresh subagent per item

Before launching, collect two inputs for the prompt:

- **Answered goal sections** — the `<key>` of every `goal-answered: <key> via <pr-url>`
  line outside the human-only fence of this item's body, or `none`.
- **Open goal questions** — `~/.claude/skills/kp-gh-lib/scripts/find-marker.sh <routed-repo> goal-ref
  --any-value --label type:question` in each routed repo (§0.2), one hit per line as
  `<goal> <title> — goal-ref: <value>` (the title from `gh issue view <m> -R <repo>
  --json title -q .title`), or `none`.
  `<goal>` is `#<m>` in `<target-repo>` and `<owner>/<repo>#<m>` in another routed repo.

Launch one `general-purpose` subagent with the Agent tool and `run_in_background: false`,
using the prompt below with `<target-repo>`, `<n>`, `<spec-repo>` and both inputs filled
in. The call blocks until its result is back — never start the next item's subagent
meanwhile. A fresh subagent per item keeps one issue's evidence from colouring another's
decision.

```
Decide one GitHub decision issue on the operator's behalf: <target-repo>#<n>.
Spec repo: <spec-repo>.
Goal sections already answered on this issue: <answered goal sections>
Open goal questions:
<open goal questions>

You are read-only. Never comment on, edit, label or close an issue or PR, never
edit a file, commit or push. Use gh issue view, gh pr view, GET-only gh api, Read,
Grep and Glob.

1. Read the issue: gh issue view <n> -R <target-repo> --json title,body,comments.
   The questions are under "## The question" or "## Questions", their options under
   "## Options", the evidence inside <details>. Read the spec text its spec-ref:
   lines point to and the code, PRs and issues the details cite.
2. Decide every question yourself. The "Recommendation" line is the raising agent's
   opinion: weigh it, do not adopt it.
3. An option is CLEARLY BEST only when the evidence you read shows it meets what the
   spec and the existing code already require, and every other option breaks a
   stated requirement, contradicts existing behaviour, or is worse at no benefit.
   It is NOT clearly best when:
   - the options trade off something only the operator can weigh (cost vs. speed,
     user-facing taste, business priority, scope);
   - evidence needed to choose is missing, or you could not read it;
   - choosing needs a fact that is not written anywhere;
   - the best answer is not one of the listed options;
   - any one question of a multi-question item has no clearly best option (the
     whole item is then not clearly best).
4. Climb before skipping. When every reason in 3 is an operator-only trade-off or a
   fact written nowhere, read the spec's domain layer as defined in
   ~/.claude/skills/kp-gh-lib/NOTES.md § "Decision layers": every section of the
   spec docs whose heading matches, and the brief the spec declares as its
   requirements or design authority. Then:
   - the domain text determines an option for every question → decided;
   - the domain layer is silent on the fact that would settle it, and that fact is
     a business or domain goal → escalate. When an open goal question above asks
     for the same fact, escalate as same-as that question;
   - otherwise skip: evidence missing or unreadable, the best answer not listed, a
     missing fact that is technical (a library capability, a portal limit), or a
     fact that belongs in a goal section already answered on this issue.
5. Reply with exactly one first line, then the rest:
   decided: <answer>          one listed option per question: "B", or "1B 2A"
   escalate: <the missing fact, in one sentence>
   escalate: same-as <goal>   the open goal question, written as it is listed above
   skip: <one sentence why>
   After "decided:", give 2-4 plain sentences on why that option is clearly best,
   citing the evidence (spec section, file:line, issue or PR number). A choice the
   domain layer determined quotes the deciding domain phrase and names its section.
   After "escalate: <fact>", give, in this order:
   - "goal-ref: <key>": the domain section the fact belongs in, as
     <doc-slug>#<heading-path-slug> (the key kp-sync-spec-tasks §1 derives), or
     <brief-file>#<heading-path-slug> for the brief;
   - one to three domain questions written per NOTES § "Human-gated item body"
     ("## The question" or "## Questions", each with "## Why it matters",
     "## Options" described by their business effect, and a Recommendation);
   - "## What this settles": one line per domain option naming the option of each
     original question it would settle, "A → B" or "1A → 1B 2A";
   - 2-4 plain sentences on why the requirement-level evidence does not settle it
     and which domain sections you read.
   After "escalate: same-as <goal>", give 1-2 sentences on why that question asks for
   the same fact.
```

**Check the verdict.** Its first line must be one of:

- `decided: <answer>`, naming exactly one option letter listed in the body for **every**
  question → §4.1;
- `escalate: <missing fact>` followed by every part the prompt asks for — a `goal-ref:`
  key, one to three domain questions each with listed options, and a "## What this
  settles" line for every domain option naming a listed option of **every** original
  question — whose key is none of the answered goal sections → §4.0;
- `escalate: same-as <goal>`, where `<goal>` is one of the open goal questions passed
  in, written as it was listed → §4.0;
- `skip: …` → outcome **skipped** with its reason.

Anything else — no verdict, an unlisted letter, a question left out, an invented option,
a missing escalation part — is outcome **skipped** (`subagent verdict unusable: <what>`).
So is an escalation to an answered goal section: that refusal is the loop guard, and
since a spec has finitely many domain sections, an item climbs a bounded number of
times. A skipped item gets no comment and no change.

## 4. Record and resolve

### 4.0 Escalate in place

An `escalate:` verdict means the choice turns on a domain goal the spec never states
(`~/.claude/skills/kp-gh-lib/NOTES.md` § *Decision layers*). The domain layer is the
operator's, so this item becomes their question about that goal, on the same issue, and
nothing is launched. `kp-resolve-spec-decision` writes the answer into the spec's goal
section and restores the decision once that spec PR merges; a later run decides it
against the written goal. In every command below, write a `'` inside a substituted value
as `'\''`.

**Duplicate goal.** An `escalate: same-as <goal>` verdict, or an `escalate:` whose key
an open goal question in a routed repo (§0.2) already carries, rewrites nothing. Find
that question with `~/.claude/skills/kp-gh-lib/scripts/find-marker.sh <routed-repo> goal-ref
<key>` in each routed repo. `<goal>` is the hit, picked
and written as `~/.claude/skills/kp-gh-lib/NOTES.md` § *Before raising a human-gated
item* branch 4 picks and writes it, with `<target-repo>` as the item's repo:

1. Add a `blocked-by: <goal>` line with `~/.claude/skills/kp-gh-lib/scripts/set-marker.sh <target-repo> <n>
   blocked-by --add <goal>`, after the `edge-check.sh` check `kp-resolve-spec-decision` §4.3 applies to a
   blocker. If it drops the edge, the outcome is **skipped**
   (`waits on goal <goal>, edge dropped: <why>`) and step 2 is not posted.
2. Post once — unless a comment carrying the marker below and naming `<goal>` is already
   there — `Waiting on goal question <goal>: <missing fact>.`, a blank line, and
   `<!-- kp-resolve-spec-decision-auto:waiting-on-goal -->`.

Outcome **waiting on #m**.

**Otherwise, rewrite this item.** Draft and build the new body, then hand the whole
rewrite to one call.

1. **Draft the goal question** per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Human-gated
   item body* and its § *Goal questions*: the title is the original's `[<REPO-CODE>] `
   prefix plus the domain question, the blurb says which technical choice is stuck and
   which goal is missing, and `<details>` carries the original question(s) in short form
   and the original evidence. Run that section's self-check on the draft.
2. **Build the body file.** The marker lines are copied from the current body by jq,
   never retyped, so each stays byte-identical; `goal-ref:` is added beside them (a
   `goal-ref: <key>` already there from a partial earlier run is not copied twice):

   ```bash
   { printf '%s\n' '<!-- human-only:start (not LLM/spec context) -->' '> **For humans:** <which technical choice is stuck> — <which goal is missing>.' '<!-- human-only:end -->' ''
     gh issue view <n> -R <target-repo> --json body --jq '
       .body | split("\n")
       | reduce .[] as $line ({fenced: false, markers: []};
           if ($line | test("<!-- human-only:start|^<details")) then .fenced = true
           elif ($line | test("<!-- human-only:end|^</details>")) then .fenced = false
           elif (.fenced | not) and $line != "goal-ref: <key>" and ($line | test("^(spec-ref|blocks|blocked-by|resolves|slice|parent|milestone|spec-pr|goal-ref|goal-answered): ")) then .markers += [$line]
           else . end)
       | .markers | join("\n")'
     printf '%s\n\n' 'goal-ref: <key>'
     cat <<'EOF'
   <the subagent's domain questions, each with Why it matters, Options and Recommendation>

   ## What this settles
   <the subagent's settle-lines>

   ## To resolve
   Reply "A" / "B" (or your own answer in a sentence), then run `/kp-resolve-spec-decision <n>`.

   <details><summary>Details for the resolving agent</summary>

   <the original question(s) in short form, the original evidence, and the subagent's reasons>
   </details>
   EOF
   } > "<logdir>/goal-<n>.md"
   ```

3. **Escalate — one call:**
   `~/.claude/skills/kp-gh-lib/scripts/goal-question.sh escalate --repo <target-repo>
   --issue <n> --goal-title '<drafted title>' --goal-body-file "<logdir>/goal-<n>.md"
   --goal-ref '<key>' --missing-fact '<missing fact>'`. It records before acting, and
   each step checks before it acts, so a re-run finishes a partial escalation instead of
   repeating it. First the escalation comment, which `kp-resolve-spec-decision` restores
   from: the original title and body byte for byte, in a backtick fence one longer than
   the body's longest backtick run, with `goal-ref: <key>` and
   `restore-type: type:decision` — not posted again when the latest escalation comment
   newer than any restore already carries this key (`action: already-escalated`). Then
   the title and body, then the label swap `type:decision` → `type:question`, last:
   this run selects on `type:decision`, so the item stops being agent-answerable only
   once everything else is in place; until then §2 recognises the rewritten body by its
   `goal-ref:` line. Assignee and priority are unchanged — the item was already
   human-gated — and no board call is made. Exit `3` (the comment could not be posted,
   nothing changed) or `1` (a later step failed; `skipped` names it) is outcome
   **skipped** (`escalation failed: <step>: <reason>`); a re-run finishes it.

Outcome **escalated → goal question**.

### 4.1 Post the decision

Before anything is launched, so the record survives a failed resolve:

```bash
gh issue comment <n> -R <target-repo> --body "$(cat <<'EOF'
**Decision (agent, via /kp-resolve-spec-decision-auto):** <answer>

Expanding <answer> per the issue body: <option name, per question>.

<the subagent's reasons, verbatim>

An independent subagent chose this because it was clearly best on the evidence above; the operator did not pick it personally. To override it, comment your own decision and run `/kp-resolve-spec-decision <n>` — or, once this issue is closed, `/kp-resolve-spec-decision <n> --decision "<your decision>"`.

<!-- decision-source: kp-resolve-spec-decision-auto -->
EOF
)"
```

Post it only when §2 found no decision comment, so a re-run never stacks a second one.
Keep the reasons as the subagent wrote them; the expansion line only names the chosen
options from the body. When the reasons derive the choice from the domain layer, add one
line after the expansion line: `Derived from the spec's goal in <section>: "<the domain
phrase the reasons quote>".` On a research gate item, the override sentence reads `To
override it, comment your own decision here and run /kp-resolve-spec-research
<research-n>.` instead: its answer is read by that research, never by the resolver.

### 4.2 Run the resolver headless

`kp-resolve-spec-decision` is `disable-model-invocation`, so the Skill tool cannot load
it; a headless `claude -p` child runs it as the loop skills run theirs. Wait for it per
`~/.claude/skills/kp-gh-lib/NOTES.md` § *Waiting in a headless session* — it opens a
worktree and a PR, then waits on its own `kp-do-gh-pr-loop` child for the whole review
loop, which passes the 10-minute foreground cap many times over. Launch and wait on it
with `~/.claude/skills/kp-gh-lib/scripts/run-child.sh` — one launch call, then foreground
`--wait` calls (`Bash` `timeout: 540000`) re-issued until the child's result line
replaces `status: running`; never `run_in_background` or `Monitor`:

```bash
~/.claude/skills/kp-gh-lib/scripts/run-child.sh --log "<logdir>/resolve-<n>.log" --cwd "$PWD" \
  --timeout-min 480 \
  -- "/kp-resolve-spec-decision <n> --repo <target-repo> --spec-repo <spec-repo> --project <project>"
~/.claude/skills/kp-gh-lib/scripts/run-child.sh --wait "<logdir>/resolve-<n>.log"
```

The script owns the detached launch, the exit sentinel (derived from the log) and the
family's standard flag set — `bypassPermissions` among them, required: the resolver
edits issues, branches, pushes, opens a PR and launches the pr-loop with no human
present. `--timeout-min 480` kills a child that overruns eight hours; it ran unbounded
before.

**Research gate item.** Launch `kp-resolve-spec-research` for `<research-n>` in place of
the resolver. `--chrome` is how a headless child gets the Claude-in-Chrome tools its
research needs (`kp-resolve-spec-research` § *Chrome in a headless child*); without them
its Chrome gate stops the child cleanly, and §4.3 reports it:

```bash
~/.claude/skills/kp-gh-lib/scripts/run-child.sh --log "<logdir>/research-<research-n>.log" \
  --cwd "$PWD" --timeout-min 480 --chrome \
  -- "/kp-resolve-spec-research <research-n> --repo <target-repo> --spec-repo <spec-repo> --project <project>"
~/.claude/skills/kp-gh-lib/scripts/run-child.sh --wait "<logdir>/research-<research-n>.log"
```

The wait is the same, and so is the capacity check on its result line: that skill quotes
the limit line any of its children hit verbatim in its report. It runs the resolver and
drives the resulting coding items itself, so the wait covers all of them.

**Capacity check.** It is the `capacity=` field of the `--wait` result line; anything
but `none` is a hit. The resolver quotes its pr-loop's limit line verbatim in its report
(`kp-resolve-spec-decision` step 5), so this one field catches a limit in either session.
On a hit the limit is account-wide: every later item is **not attempted**. Still read
§4.3 for this item — an **OPEN** issue is outcome **capacity-limit**, and the decision
comment stays, so the next run resumes it at §4.2; a **CLOSED** one is **resolved**, and
a spec PR its resolver comment names has outcome **merged** when §4.4 reads `MERGED`,
else **capacity-limit** — then go straight to §5.

### 4.3 Outcome from GitHub, not the log

`gh issue view <n> -R <target-repo> --json state,comments`:

- **CLOSED** → outcome **resolved**. Take the downstream item and spec PR from the
  resolver's `Resolved → …` or `Closed as won't-do …` comment. When that comment names a
  spec PR (`…, PR <pr-url>`), go to §4.4; a `no spec change: …` resolve has no PR, and
  the item is done.
- **OPEN**, carrying a `<!-- kp-resolve-spec-decision:no-decision -->` comment with no
  §3 decision comment newer than it (a `kp-resolve-spec-decision` §3 (a) or (c) source)
  → outcome **no-decision**, with the log path: the resolver found nothing to resolve
  and left its question on the issue. No board call is made for it.
- **OPEN** otherwise → outcome **resolve failed**, with the log path. The decision
  comment stays, so a re-run resumes at §4.2 without deciding again.

**Research gate item** — read the gate item the same way, then:

- **CLOSED** → outcome **research resumed**. `gh issue view <research-n> -R <target-repo>
  --json state,comments` gives the research state, first match wins:
  - **CLOSED** → **resolved**: take the spec PR from its resolver's `Resolved → …` or
    `Closed as won't-do …` comment and go to §4.4;
  - **OPEN**, with an open gate item for `<research-n>` newer than this one (found as
    `kp-resolve-spec-research` §2.2 finds one) → **new gate item #m**;
  - **OPEN**, with a `<!-- decision-source: kp-resolve-spec-research -->` findings comment
    newer than this gate item's close → **concluded, no-decision** when `<research-n>`
    carries a `<!-- kp-resolve-spec-decision:no-decision -->` comment with no §3 decision
    comment newer than it, else **concluded, resolve failed** — with the log path;
  - **OPEN** otherwise → **not concluded**, with the log path.
- **OPEN**, and the research item's latest decision comment — found as
  `kp-resolve-spec-research` §3.1 finds it — is a person's → outcome **research already
  answered**: the child stopped there without closing the gate item, and the research
  item needs the resolver, not another research run.
- **OPEN** otherwise → outcome **research resume failed**, with the log path: the child
  stopped at a gate (Chrome not connected, for one) or failed before closing it. The decision
  comment stays, so a re-run resumes at §4.2 without deciding again.

### 4.4 Read the spec PR outcome

Only a **resolved** item whose resolver comment names a spec PR reaches this step — or a
**research resumed** gate item whose research item's resolver comment names one.
`<pr>` is the number at the end of `<pr-url>`. It launches nothing: the resolver ran
`/kp-do-gh-pr-loop` on that PR in its own headless session before it exited
(`kp-resolve-spec-decision` §4.7), so a second launch here would drive the same PR
twice. By the time §4.2's wait returns that loop has finished, and a merged spec PR is
already in the spec text the next decision reads.

**Spec PR outcome from GitHub, not the log** —
`~/.claude/skills/kp-gh-lib/scripts/item-outcome.sh <spec-repo> --pr <pr>`
(`kp-gh-lib/SKILL.md` § *`item-outcome.sh`*; a capacity-limit comes from §4.2's
check instead):

- `merged` → **spec PR merged**;
- `blocked-on-decision` → **spec PR blocked on decision #d**, `d` its `decision=`;
- `parked` → **spec PR parked**, with the resolver's log path (its report names the
  pr-loop's own log);
- `pr-closed` → **spec PR closed**;
- a non-zero exit → **spec PR parked**, with the script's stderr.

A non-zero child exit is not the outcome; GitHub state is. **An unmerged spec PR never
ends the run:** record it and go on to the next item, which may then read spec text
without that change. A re-run will not retry it — it selects only open decision items —
so the report carries the command to drive it again.

## 5. Report

Print the target repo, spec repo and project,
then every item by outcome, with number and title:

- **resolved** — the answer, the decision comment URL, the downstream item or "won't
  do", and the spec PR with its outcome (merged, blocked on decision #d, parked, closed
  or capacity-limit). For a spec PR that did not merge, also the resolver's log path and
  `/kp-resolve-spec-decision <n> --repo <target-repo>`, run from the spec-repo checkout,
  to drive it again and sync the items to the merged text; `/kp-do-gh-pr-loop <pr>` alone
  merges it but skips that sync. A `no spec change` resolve says so;
- **escalated → goal question** — the domain question, its `goal-ref` key and the
  escalation comment URL, with `/kp-resolve-spec-decision <n>` for the operator to run
  once they have answered it;
- **waiting on #m** — the unmet blocker, or the open goal question this decision waits
  on;
- **skipped** — the subagent's reason;
- **left to the operator** — an audit-close decision, with `/kp-resolve-spec-decision
  <n>` for the operator to run once they have answered it;
- **already answered** — with `/kp-resolve-spec-decision <n>` to run;
- **no-decision** — the log path and the no-decision comment URL, with
  `/kp-resolve-spec-decision <n>` to run once the operator has replied there;
- **resolve failed** — the log path;
- **research resumed** — the answer, the decision comment URL, and the research item's
  state: resolved, with its spec PR and outcome as for **resolved**; new gate item #m;
  concluded, no-decision; concluded, resolve failed; or not concluded. Always the research log path, and unless
  resolved, `/kp-resolve-spec-research <research-n>` to resume it;
- **research already answered** — a person decided the research item itself, with
  `/kp-resolve-spec-decision <research-n>` to run;
- **research already closed** — the closed research item and the close comment URL, or
  the close failure a re-run retries;
- **research resume failed** — the log path and `/kp-resolve-spec-research <research-n>`;
- **not classified** — the `decision-state.sh` message; a re-run retries it;
- **capacity-limit** / **not attempted** — with the reset time when the result line's `reset=` gives one.

## Invariants

- **Never asks the operator; a missing input stops the run with the flag to pass.**
- **Only open `type:decision` items are decided or changed.** Other issues are read only
  as a blocker's state, as §3's open goal questions, or as a gate item's research item.
- **Never decide an audit-close decision.** Option B accepts a milestone with findings
  still open; only the operator can accept that.
- **A person's decision always wins.** An item a person already answered is never
  decided by an agent, and a person's later decision supersedes an agent decision.
- **No clearly best option, no decision.** The subagent's verdict is the only source of
  an agent decision; a skip or an unusable verdict posts nothing and changes nothing.
- **Climb before skipping; never answer a goal.** An operator-only trade-off or an
  unwritten fact is checked against the spec's domain layer
  (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Decision layers*). A question the domain
  layer leaves open goes to the operator as a `type:question`, which this skill never
  selects, and an item never escalates to a goal section it already has answered.
- **Escalate in place, recoverably.** The original title and body go verbatim into the
  marked escalation comment before the item is rewritten, marker lines are copied by jq
  and never retyped, and the label swap comes last. A decision that needs a goal another
  open question already asks for waits on it through `blocked-by:` and is never turned
  into a duplicate question.
- **One fresh subagent per item**, read-only, deciding independently of the
  Recommendation line.
- **Record before acting, once.** The marked decision comment is posted before the
  resolver runs, at most once per item.
- **This skill resolves nothing itself.** Spec edits, downstream items, re-pointing,
  closing and syncing items to the merged spec are `kp-resolve-spec-decision`'s, run in
  its own headless session. That session launches the `kp-do-gh-pr-loop` that drives
  the spec PR to merged; this skill launches no pr-loop of its own and never merges,
  reviews or fixes the PR. For a research gate item the child is
  `kp-resolve-spec-research`, which researches, runs the resolver and drives the
  resulting coding items; this skill only reads their outcome.
- **One item at a time**, and never end the turn while a resolver child — and so its
  pr-loop — is still running: foreground waits only, never `run_in_background` or
  `Monitor`.
