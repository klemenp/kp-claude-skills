---
name: kp-resolve-spec-decision
description: Resolve a spec decision/question/conflict/research issue from the operator's decision — given as an issue comment or stated in the Claude Code session (then transcribed) — or from an agent decision posted on the issue (kp-resolve-spec-decision-auto's decision, or kp-resolve-spec-research's marked findings on a research issue, either superseded by a person's later decision), then amend the spec doc, reconcile the items referencing it, create or reuse the downstream item gated on the spec PR, close the decision, merge a clean spec PR itself or drive it to merged via a headless /kp-do-gh-pr-loop, and sync the items to the spec text that merged. A goal question — about a domain goal the spec never states — instead amends the spec's goal section, stays open, and is restored to its original decision once that spec PR merges. An audit-close decision changes no spec. In a project with no spec repo, it instead folds the answer into the body of each coding item the decision blocks and closes the decision. Manual-only.
disable-model-invocation: true
argument-hint: [issue-number...] [--repo <owner/name>] [--spec-repo <owner/name>] [--project <number|owner/number|id>] [--decision "<text>"]
allowed-tools: Read, Grep, Glob, Edit, Write, Agent, Bash(gh issue:*), Bash(gh issue comment:*), Bash(gh issue close:*), Bash(gh issue edit:*), Bash(gh issue reopen:*), Bash(gh project:*), Bash(gh label:*), Bash(gh repo:*), Bash(gh api:*), Bash(gh pr list:*), Bash(gh pr view:*), Bash(gh pr diff:*), Bash(gh pr merge:*), Bash(gh pr comment:*), Bash(gh pr checks:*), Bash(~/.claude/skills/kp-gh-lib/scripts/spec-pr-check.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/spec-pr-fastmerge.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/spec-branch.sh:*), Bash(grep:*), Bash(date:*), Bash(git rev-parse:*), Bash(git log:*), Bash(git -C:*), Bash(git add:*), Bash(git commit:*), Bash(git push:*), Bash(~/.claude/skills/kp-gh-lib/scripts/resolve-board.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/item-id.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/milestone-of.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/milestone-place.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/create-item.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/lint-item.py:*), Bash(~/.claude/skills/kp-gh-lib/scripts/read-context.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/run-child.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/find-marker.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/comment-once.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/set-marker.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/goal-question.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/decision-state.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/linked-item.sh:*), Bash(jq:*), Bash(cat:*), Bash(sleep:*), Bash(echo:*), Bash(head:*), Bash([:*), Bash(true:*), Bash(claude:*), Bash(~/.claude/skills/kp-gh-lib/scripts/edge-check.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/audit-close-move.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/fresh-checkout.sh:*)
---

# Resolve a spec decision

Companion to `kp-sync-spec-tasks`. Takes a `type:decision` / `type:question` /
`type:conflict` / `type:research` issue, reads the **operator's decision** — from the
issue's latest human comment, or stated directly in the Claude Code session — or the
marked **agent decision** `kp-resolve-spec-decision-auto` or `kp-resolve-spec-research`
posted when the operator ran it, and applies it everywhere the requirement is recorded:
the **spec doc**, the **items that already carry or reference its `spec-ref`**, and the **downstream item** (created or
reused), before closing the decision issue. A decision given in the session is
**transcribed to an issue comment before anything else happens**, so the audit trail
on GitHub is identical either way.

A resolution is not finished when the decision issue closes. It is finished when the
spec PR carrying it has merged, and the spec text, the board, the dependency markers and
the items all agree with what merged.

This skill runs **inline (no fork)** on purpose: it interprets a human judgement
and acts on it, and the operator may want to see/steer that reasoning in the main
thread. It handles one issue, or a batch of answered issues (§ *Batch run*), not the
whole repo, so isolation buys nothing. The long
part — reviewing and fixing the spec PR until it merges — runs in a headless
`kp-do-gh-pr-loop` session that this skill launches and waits on (§4.7), unless the PR is
clean enough for §4.7's fast path to merge it here.
When a decision stated in the session does not determine an outcome, step 3 asks the
operator one targeted question and waits for the answer. A fork cannot serve an operator
who is in the loop mid-run, so this skill stays inline.

## Procedure

1. **Resolve the target.** This run's arguments: `$ARGUMENTS` (empty if none). They are
   one or more issue numbers (required; if missing, stop and ask for one) plus optional
   `--repo <owner/name>`, `--spec-repo <owner/name>`, `--project
   <number|owner/number|id>` and `--decision "<text>"`. Each number is bare (`<n>`, its
   target repo resolved as below) or qualified (`<owner/repo>#<n>`, its own target repo —
   for a qualified number its own repo wins over config `targetRepo`, in a single-number
   run too). Two or more numbers make a **batch run** (§ *Batch run*); `--decision
   "<text>"` with two or more numbers stops before anything is posted, with
   `--decision applies to one issue; run /kp-resolve-spec-decision <n> --decision "…"`.
   A single number runs exactly as before; § *Batch run* applies only to two or more.

   **Target repository.** The decision issue and any downstream item live in the
   app/service repo, not the spec repo. Resolve `<target-repo>` in order: the repo of
   a qualified `owner/repo#n` number → the `--repo` argument → config `targetRepo` →
   otherwise **ask the user**. Never default to the
   spec repo. Every `gh issue` / `gh label` call below runs against it with
   `-R <target-repo>`.

   **Spec repository (where the spec docs live).** The decision issue is in the
   target repo, but the spec text it resolves is in the spec repo, and the two are
   routinely different (a `shop-app` decision is amended by a `shop-spec` PR).
   Resolve `<spec-repo>` in order: the `--spec-repo` argument → config
   `.claude/spec-sync.json` `specRepo` → the repo of the **current checkout** if
   that checkout actually contains spec docs (probe config `specGlobs`, else
   `docs/specs/**/*.md`, `specs/**/*.md`, `SPEC*.md`) → otherwise **ask the user**,
   with one exception. When there is no `--spec-repo`, the working checkout's
   `.claude/spec-sync.json` exists with its `specRepo` key absent, `null` or the empty
   string (all three mean the same), and the spec-docs probe finds nothing, the project
   has **no spec repo**: the run does not ask, and every number in it takes § *No-spec-repo
   branch*. With no `.claude/spec-sync.json`, it still asks.
   The worktree flow needs a **local primary checkout of the spec repo**: confirm
   `git rev-parse --is-inside-work-tree` succeeds and `git rev-parse --show-toplevel`
   is that repo. If the session is running inside the target repo (or any other
   repo) instead, **do not branch there** — skip the spec edit and report it as not
   applied, per §4.5. Everything that does not touch spec text still runs normally.

   **Project.** Resolve the GitHub Project (v2) to attach any downstream item to,
   in order: the `--project` argument → config `.claude/spec-sync.json` `project` →
   otherwise **ask which project** by listing candidates
   (`gh project list --owner <repo-owner>`, `gh project list --owner @me`) and
   stopping for a selection. Record its **owner login and number**; the owner login
   is reused in §4.3 to assign human-gated items.

   **Project id + `Priority` field — 1 point.**
   `~/.claude/skills/kp-gh-lib/scripts/resolve-board.sh <owner> <number>`; its output is
   in `~/.claude/skills/kp-gh-lib/SKILL.md` § `resolve-board.sh`.

   Capture the option id for the **highest** priority (commonly `High` / `Urgent` /
   `P0`, else the top-listed option; ask which option means "highest" if the naming
   is ambiguous). If the board has no `Priority` field, skip prioritisation as
   best-effort and report it.

   **GitHub API budget.** Per `~/.claude/skills/kp-gh-lib/NOTES.md` § *GitHub API
   budget*.

   **Config.** Read `.claude/spec-sync.json` from the working checkout when present
   for `targetRepo`, `specRepo`, `project`, `repoCodes`, `labels`, `typeLabels`,
   `epicMapping`, `requirementRepos` and `specGlobs` — the downstream item must follow the same
   conventions as everything `kp-sync-spec-tasks` creates.

2. **Read the issue.** `gh issue view <n> -R <target-repo> --json
   number,title,body,labels,state,comments`. Extract:
   - `spec-ref:` from the body (the requirement identity). A `type:conflict` issue
     spans two or more spec docs by definition — capture **every** `spec-ref:` line
     it carries, plus any requirement id its body names as the counterparty, and
     treat the resolution as touching all of them.
   - the type label (`type:decision` / `type:question` / `type:conflict` /
     `type:research`).
   - a `goal-ref:` line → the issue is a **goal question**:
     `kp-resolve-spec-decision-auto` §4.0 rewrote a decision, or a creating skill raised
     the item, around a domain goal the spec never states, and § *Goal-answered
     branch* changes §4 for it. A `type:question` issue with no `goal-ref:` but a
     `goal-answered:` line naming the PR of its latest `Goal recorded → PR <pr-url>`
     comment is a restore that stopped part-way when no
     `<!-- kp-resolve-spec-decision:restored -->` comment follows that one, or when the
     restore's type (the latest escalation comment's `restore-type:`) is not
     `type:question`: finish that branch's restore steps, skipping those already done, and
     report.
   - an `audit-close: M<k>` line → the issue is an **audit-close decision** the task
     loops raised after six audit rounds of milestone M<k>
     (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Milestone sequencing* → *Audit gate*);
     § *Audit-close branch* replaces §4 for it.

   Ignore anything inside the `<!-- human-only:start ... -->` /
   `<!-- human-only:end -->` fence when extracting markers — it is a human
   reading aid, not authoritative.

3. **Find the decision.** It arrives from one of three sources, and every one ends up
   as a comment on the issue. (a) and (b) are the operator's own words; (c) is an
   agent's — posted by `kp-resolve-spec-decision-auto` or `kp-resolve-spec-research`
   because the operator ran it, or by the creating skill at filing on a creator-decided
   item.

   Read the issue's comments once, classified:
   `~/.claude/skills/kp-gh-lib/scripts/decision-state.sh <target-repo> <n>`
   (`kp-gh-lib/SKILL.md` § *`decision-state.sh`*). It applies the marker rules —
   which comments are skill output, bot-authored, or before the latest
   `<!-- kp-resolve-spec-decision:restored -->` comment (an answer given to a goal
   question is not a decision on the restored one) — so this step never restates them.
   Exit `1` or `2` leaves no decision to read: stop and report the message.

   **(a) On the issue.** The newest `humanCandidates` entry that picks an outcome; failing
   that, `session` — an earlier run's (b) transcription — when `latest` is `session`.

   **(b) In the Claude Code session.** The operator states the decision in a chat
   turn ("Option A — …", "won't do, drop it") or passes `--decision "<text>"`.
   This counts *only* when the operator stated it themselves in this session. It is
   **never** inferred from the issue's own Recommendation, from your reading of the
   options, from a subagent's output, or from silence. If what they said does not
   determine an outcome, **ask one targeted question — do not transcribe a guess.**

   **(c) Agent-decided, on the issue.** The script's `agent`, its `skill` naming the
   source: `kp-resolve-spec-decision-auto` after a fresh subagent found one option clearly
   best, or the creating skill at filing when every Recommendation was `confidence: high`
   (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Human-gated item body* → *Confidence and creator-decided items*) — its
   answer and expansion line are the decision — or, on a `type:research` issue,
   `kp-resolve-spec-research` when its research concluded — its `## Resolution` section is
   the decision. None needs transcription. It counts only while it is the **latest**
   decision on the issue: a `humanCandidates` entry that **picks an outcome** (`B`,
   `Option A — …`, `1B 2A`, "won't do", a sentence answer), or a (b) statement,
   supersedes it; a candidate that only discusses or asks does not. No other agent output
   is a decision, and this skill never posts a (c) comment.

   When the decision came from (b), **transcribe it to the issue before doing
   anything else** — before any create, edit, worktree, or close, so the record
   survives a later failure:

   ```
   gh issue comment <n> -R <target-repo> --body "$(cat <<'EOF'
   **Decision (operator, via Claude Code):**

   > <the operator's words, verbatim>

   <!-- decision-source: claude-code-session -->
   EOF
   )"
   ```

   Quote them **verbatim**; never rewrite, soften, or extend the decision. You may
   append at most one line of *mechanical* expansion, clearly marked as such. It may
   resolve a bare "Option A" against the option text already in the issue body
   (`Expanding Option A per the issue body: …`), or numbered answers such as `1B 2A`
   against the numbered questions and their options in the body
   (`Expanding 1B 2A per the issue body: 1 — …; 2 — …`). Anything beyond that is a
   question for the operator, not a transcription.

   Skip the post if an identical `decision-source: claude-code-session` comment is
   already on the issue (re-run safety). If a session decision contradicts an
   earlier human comment, the session statement is the later word: transcribe it,
   note in its body that it supersedes comment `<url>`, and flag the supersession in
   the report. A superseding decision on an **already-closed** issue is the one case
   that overrides the no-op guard in §4.1 — see there.

   When a source (a)–(c) yields a decision, §3.1 is skipped and the run proceeds to
   §4 unchanged.

   If **no source yields a decision**, present the question to the operator per §3.1,
   then leave a trace on the issue: post that same presentation (the question, the
   options and the recommendation, in plain words) as one issue comment whose first
   line is `<!-- kp-resolve-spec-decision:no-decision -->` and whose last line is
   `Reply here, then run /kp-resolve-spec-decision <n>`, with `<n>` the issue's number.
   Write it to a file and post it with
   `~/.claude/skills/kp-gh-lib/scripts/comment-once.sh <target-repo> <n> --marker
   '<!-- kp-resolve-spec-decision:no-decision -->' --body-file <file>`, which posts
   nothing when a comment already carries the marker, so a re-run stacks nothing.
   Either way, report `no-decision <repo>#<n>`, then end the turn so the operator can
   reply — ending the turn is the wait; there is no polling. **Do not guess.** The
   reply is a (b) session decision: transcribe it verbatim as above before any other
   action, then continue with §4. If the reply does not determine an outcome, ask one
   targeted question, as (b) requires.

   **3.1 Presenting an unanswered question.** Covers a `type:decision`,
   `type:question` (goal questions included), `type:conflict` or audit-close issue with
   no decision:

   - **Question** — one plain sentence ending in "?". An issue with several numbered
     questions (at most three, per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Human-gated
     item body* → *Several questions in one impasse*) shows each one in turn, numbered,
     each with its own options, recommendation and note.
   - **Options** — each as a letter, a short name, and one line on its effect the
     operator or a user would notice. A `type:question` body with
     "## What I need from you" instead of "## Options" (NOTES → *Per-type variation*)
     shows no options: it shows that section's requested answer shape (e.g. "a
     retention period in days") and asks for it.
   - **Recommendation** — taken from the issue body: which option and a one-line
     reason. When the body has none, or says "No recommendation", show
     "No recommendation" with the body's stated reason, or "the issue gives no reason".
     Never invent a recommendation.
   - **Why / impact** — at most 3 plain sentences on what the recommended option (or,
     with no recommendation, each option) leads to, drawn from the body's "## Why it
     matters" text and the options' *Good:* / *Cost:* text. Include it whenever the
     body has any of that text; omit it only when the body has none — never invent one.
   - **Reply forms** — `A` / `B`, `1B 2A` for numbered questions, or a sentence.

   Plain words throughout: no REQ ids, SHAs, file paths or spec anchors in the
   presented text. Source it from the body's `## The question`, `## Why it matters`,
   `## Options` and `**Recommendation:**` sections when present. For an older body
   without them, the question is the body's first sentence ending in "?" (or, if none,
   a one-sentence restatement of what it asks the operator to decide), the options are
   any lettered or bulleted alternatives it lists, and the recommendation is shown only
   if the body states one — otherwise "No recommendation" with "the issue gives no
   reason".

   A `type:research` issue with no decision is not presented and does not wait: print
   `Research on #<n> has not concluded — run /kp-resolve-spec-research <n> first.`,
   post that sentence alone as the body of one issue comment whose first line is
   `<!-- kp-resolve-spec-decision:no-decision -->` — no `Reply here` line, as the
   research skill is the one to run — written to a file and posted through the same
   `comment-once.sh <target-repo> <n> --marker
   '<!-- kp-resolve-spec-decision:no-decision -->' --body-file <file>` call, report
   `no-decision <repo>#<n>` and stop. Its body is not in the human-gated template, and answering it is that skill's
   job.

4. **Apply the decision.** Interpret the decision from §3, then work through §4.1–§4.8
   in order. On a goal question (step 2), § *Goal-answered branch* says how each of them
   changes; on an audit-close decision, § *Audit-close branch* runs instead. A batch run
   (two or more numbers, §1) follows § *Batch run*.

### 4.1 Idempotency guard (before creating or editing anything)

**The search form is load-bearing.** Every marker lookup below is a
`~/.claude/skills/kp-gh-lib/scripts/find-marker.sh` call, never a hand-written search: an
unquoted phrase makes GitHub read `resolves:` / `spec-ref:` / `blocked-by:` as unknown
search qualifiers and return a silently wrong set — measurably over-broad, not
empty — and "reuse the number you found" against a wrong hit is worse than a
duplicate. The script quotes the phrase and returns only issues carrying the exact
marker line outside the human-only fence and `<details>`.

- If `gh issue view <n> -R <target-repo>` already shows the decision issue
  **CLOSED**, treat the run as a no-op: find the downstream item it produced
  (`~/.claude/skills/kp-gh-lib/scripts/find-marker.sh <target-repo> resolves '#<n>' --state all`) and the spec PR it records (the `spec-pr:` marker on
  that item, else the `PR <url>` in this skill's close comment), and read that PR's
  state. An **open** spec PR is driven again: make sure the downstream item, when there
  is one, carries its §4.5 `blocked-by:` edge, then — only when §1 confirmed this
  session is the spec-repo primary checkout — run §4.7 and, on a merge, §4.8. From any
  other checkout, launch nothing and report it as **not driven — no spec checkout**
  (§4.7). A **merged** or **closed** one, or none, is only re-reported. Then report and
  stop.
  **Exception:** a decision transcribed in §3 that explicitly supersedes the one this
  issue was closed on. Then do not no-op — reopen the issue
  (`gh issue reopen <n> -R <target-repo>`), apply §4.2–§4.8 against the **existing**
  downstream item (edit it; never a second create), and state plainly in the report
  that a prior resolution was superseded.
- Otherwise, before any `gh issue create`, run **both** searches:
  `'"resolves: #<n>"'` (a downstream item this decision already produced) and
  `'"spec-ref: <key>"'` with `--state all` (any item already tracking the same
  requirement — a coding item filed before the ambiguity surfaced, an epic, a
  previous round's item). If either finds a confirmed match, **reuse that item**:
  edit it to carry the decision (§4.2) rather than creating a sibling. A research gate
  item (its body carries `<!-- kp-resolve-spec-research:gate`) is a question, not
  tracking work, and is never a match. A reused item
  carrying `goal-ref:` is first repaired per `~/.claude/skills/kp-gh-lib/NOTES.md`
  § *Before raising a human-gated item*. Never create a second item for a requirement
  that already has one.

### 4.2 Branch on the decision

- **Resolved → downstream work.** Reuse the item found in §4.1 when there is one;
  otherwise create it. Either way it carries the **same `spec-ref`** plus a
  `resolves: #<n>` line. Begin the body with the human-only fence
  (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Human-only fence*), with all machine
  markers outside the fence below it:

  ```
  <!-- human-only:start (not LLM/spec context) -->
  > **For humans:** <plain summary of the resolved task and the decision behind it>
  <!-- human-only:end -->

  <contract sections, on a created type:coding item>

  spec-ref: <key>
  resolves: #<n>
  ```

  When reusing an existing item, **edit surgically**: add the missing markers and
  amend only the scope the decision changed, leave the rest of the body alone, and
  say in the report that the item was reused rather than created. When the reused body
  has a `### Context` section, the edit also adds `decision: <target-repo>#<n>` to it,
  and `~/.claude/skills/kp-gh-lib/scripts/lint-item.py --repo <target-repo>` runs on
  the edited body before `gh issue edit`. Fix every `FAIL` it reports; one the body
  cannot fix takes the §4.8 fallback.

  **A created `type:coding` item carries the contract.** Its body follows
  `~/.claude/skills/kp-gh-lib/NOTES.md` § *Coding item body*, drafted per its
  *Drafting from a spec section* → *Draft*, with these differences:
  - **Held draft.** When this decision issue carries a held draft — a
    `<!-- kp-gh-lib:held-draft -->` block in its body, raised per
    `~/.claude/skills/kp-gh-lib/NOTES.md` § *Settling a failing draft* step 4, or in the
    held-item comment the exception below writes — the item starts
    from it; when both exist, the newest comment wins. Keep its `spec-ref:`, `serves:`
    and `audit-finding:` lines, apply the decision's answers, and check it as usual.
  - **Pinned commit.** `<sha>` pins spec text that already carries the decision. The
    checks below judge the draft against that text, and the decision is often what
    fills the gap they look for: a missing `Serves:` line, section or rule. So a created
    coding item waits for the spec-update worktree flow (§4.5) to push. Run that flow
    through its step 5 (publish), then pin `<sha>` to the spec PR's head
    (`gh pr view <pr> -R <spec-repo> --json headRefOid -q .headRefOid`).
    `lint-item.py` and `read-context.sh` can read any pushed commit. Then check and create
    the item. §4.4, the rest of §4.5 and §4.6 run after the create, as usual. With
    `no spec change: <why>`, the spec already says what was decided, so the pin is the
    spec base branch's current commit (`gh api repos/<spec-repo>/commits/<base> -q .sha`,
    with `<base>` the spec repo's default branch). §4.8 re-pins the item to the merged
    PR's commit.
  - **The decided text.** Context always carries `decision: <target-repo>#<n>`, so
    `read-context.sh` loads the resolution and the `decided in` back-reference §4.5
    leaves in the spec is covered. Where the decision fixes short binding wording, §4.8
    also quotes it in Rules from the merged spec section.
  - **`code:` lines** only when the current checkout is `<target-repo>`, for files the
    decision names. Otherwise there are none, since there is no checkout to check them
    against.
  - **Verify** comes from `<target-repo>`'s `CLAUDE.md`, read with `gh api`, per
    NOTES § *Coding item body* → *Drafting from a spec section* → *Draft* step 7.
  - **Markers.** The block above (`spec-ref:`, `resolves:`) plus the §4.3 `blocked-by:`
    lines, all outside the fence. The draft is written after §4.3 has settled them.

  Write the draft to `/tmp/kp-resolve-spec-decision-<n>.md`. **Before `gh issue
  create`, run both checks** from NOTES § *Coding item body* → *Drafting from a
  spec section* → *Check*, with `--repo
  <target-repo>` and no `--code-root` unless there are `code:` lines. The first is
  `~/.claude/skills/kp-gh-lib/scripts/lint-item.py`, and the second is the cold reader
  on `read-context.sh` output. The item is created with `--body-file` set to the checked
  draft. If a check cannot run (lint exit 2 or 4, `read-context.sh` exit 1 or 2), stop
  before creating the item. Any spec PR stays open, and a re-run reuses its branch and
  PR. `kp-resolve-spec-decision-auto` runs this skill, so its resolutions get the same
  checks.

  A `FAIL spec-gap`, or a draft that still fails after two rounds, goes through
  `~/.claude/skills/kp-gh-lib/NOTES.md` § *Settling a failing draft*: settled gaps are
  folded in and the item is filed once it passes; an open gap makes it a further
  human-gated downstream item (§4.3 *Human-gated body*) holding the draft. A question-5
  conflict always goes this way.

  **The exception is a gap this decision answered.** That covers a `FAIL spec-gap`
  when this issue is the spec-gap question `kp-sync-spec-tasks` filed,
  and any gap the decision's own spec change was meant to close. Raising it again would
  ask the answered question a second time. The open item would also make
  `kp-sync-spec-tasks` skip the ref for good. A gap like this means the spec edit
  is incomplete. Complete it in the worktree (for a spec gap, add the `Serves:` line the
  decision chose), commit, push, re-pin and check once more. When it still fails, or the
  spec change was not applied (no spec checkout, or a failed push) so the pin predates
  the decision, file no coding item. Leave the decision issue open, with a comment whose
  first line is `<!-- kp-resolve-spec-decision:held-item -->`, holding in order: the
  remaining gaps; the note that the spec edit is incomplete or unpushed; and a
  `<!-- kp-gh-lib:held-draft -->` line followed by the full draft, fenced as NOTES
  § *Settling a failing draft* step 4 fences it. The run reports
  `held: #<n> — re-run /kp-resolve-spec-decision <n> once the spec edit lands`, so the
  hold is never silent, and stops: §4.4 onward is left to that re-run, which re-pins to
  the spec head, starts from the held draft, re-checks it and files it complete —
  nothing is re-asked. While the decision stays open, `kp-sync-spec-tasks` keeps
  skipping the ref; that is intended, because the resolver files the item.

  The report carries the lint `INFO` line and the cold-reader result.

- **Won't do / not applicable.** Create no downstream item. Existing items for the
  requirement do not disappear on their own — sweep them in §4.4.

### 4.3 Family conventions on the downstream item

Everything created here lands on the same shared board as `kp-sync-spec-tasks` and
`kp-decompose-gh-task` output, so it follows the same conventions. On a **reused**
item, add only what is missing — never rewrite a title prefix already in use. A
reused milestone epic (a `type:epic` carrying `spec-ref: milestone:<id>`) is never
given a prefix or a `repo:` label: it has neither by design.

- **Type label.** Exactly one, per the decision: usually `type:coding` if the
  requirement is now unambiguous, or a further `type:question` if it merely narrowed
  the ambiguity. Create the label with `gh label create -R <target-repo> ... --force`
  if absent. A further human-gated type is only for a technical or feature unknown,
  never for build order (`~/.claude/skills/kp-gh-lib/NOTES.md` § *When an item is
  human-gated*).
- **Human-gated body.** A downstream item that is itself `type:decision` /
  `type:question` / `type:conflict` — raised only as that NOTES section allows — takes
  its title and body from the human-gated item body convention in
  `~/.claude/skills/kp-gh-lib/NOTES.md` § *Human-gated item body*, not the §4.2 task
  summary. Its blurb says what is still stuck, and the §4.2 markers
  (`spec-ref:`, `resolves:`) sit in the convention's marker block. Its "To resolve"
  prompt carries its own number, filled in on create per
  `~/.claude/skills/kp-gh-lib/NOTES.md` § *Creating an item* → *Pasteable-prompt
  `__ISSUE__` substitution*, which *Board* below's `create-item.sh` does. Before creating it, apply
  `~/.claude/skills/kp-gh-lib/NOTES.md` § *Before raising a human-gated item*; a goal question raised in its place keeps `spec-ref:` and
  `resolves:`, so §4.1's searches find it on a re-run.
- **Model tier.** If the item is `type:coding`, assess its tier and add exactly one
  `model:*` label per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Creating an item* →
  *Model-tier rubric* (colors in *Labels* there; create with `gh label create -R
  <target-repo> --force` if absent). Non-coding downstream items get no `model:*`
  label.
- **Repo identification.** Per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Creating an
  item* → *Repo identification*.
- **Config labels.** Apply `labels.always` from `.claude/spec-sync.json` if set.
- **Epic link.** Pick the parent epic per `~/.claude/skills/kp-gh-lib/NOTES.md`
  § *Creating an item* → *Picking the parent epic* and link the item to it per
  § *Sub-issue linking* there. If no epic exists for that doc, create no epic, file the
  item with no parent, and run the *Milestone* step below with no `--parent`.

  Under `epicMapping.strategy: "milestone"`, read the milestone table from the spec
  docs §1 resolves. If no table or several tables qualify, **stop** before anything is
  created, with a message naming the docs searched or the tables found. A missing
  milestone epic is created in the target repo. A ref the
  table leaves unplaced (in no row or in several) gets no parent: file it with no
  parent, run the *Milestone* step below with no `--parent`, and report
  `placed <ref> #<n> under M<k> — unplaced (rows: <ids or none>)`, or the report line
  `milestone: none (project uses no milestones)` when the script's JSON has
  `"milestone": null`.
- **Milestone.** Place a **created** downstream item of any type, coding or
  human-gated, including a goal question created in its place, per
  `~/.claude/skills/kp-gh-lib/NOTES.md` § *Every new item has a milestone*; a
  **reused** one keeps its parent and is not placed. The decision issue is the origin:

  `~/.claude/skills/kp-gh-lib/scripts/milestone-place.sh --project <owner>/<number> --repo <target-repo> --cache <scratchpad>/milestone-current-<owner>-<number>.json --origin <target-repo>#<n> [--parent <owner/repo#n>]`

  `--project` is §1's owner login and number; run it with only the parts that apply:
  - linked to an epic that is not a milestone epic: run with `--parent <that epic>`;
  - no epic for its doc, or an unplaced ref under the milestone strategy: run with no
    `--parent`, as *Epic link* above says;
  - under the milestone strategy, a placed ref's item: not run (the NOTES exception).
    Its milestone is `milestone-of.sh` on the parent *Epic link* chose, or that parent's
    own id when it is a milestone epic.

  *Board* below's `create-item.sh` does this placement and the *Epic link*: a case run
  with `--parent <that epic>` passes that flag to it; one run with no `--parent` passes
  neither; a case not run passes `--link-under <the parent Epic link chose>`; and a
  milestone epic created above passes `--no-place`.
- **Blockers → `blocked-by:`.** If the resolved decision still leaves the item
  dependent on other work — any **open** human-gated issue carrying
  `blocks: <key>`, or a prerequisite the decision comment names — add a
  `blocked-by: #<issue-number>` (or the cross-repo `blocked-by: <owner>/<repo>#<n>`,
  or `blocked-by: <spec-ref>` when untracked) line per blocker **outside** the
  fence. Omit when none. Do **not** record `resolves: #<n>` and `blocked-by: #<n>`
  for the same issue — the downstream item completes the decision, so the decision
  can never also block it. **Acyclicity and milestones (hard invariants):** before
  writing `blocked-by: Y`, check the edge with
  `~/.claude/skills/kp-gh-lib/scripts/edge-check.sh --project <owner>/<number>
  <item> <Y>` (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Milestone sequencing*); before
  the item exists, `<item>` is `draft:<M<k>|none>` — the milestone of the parent *Epic
  link* chose, per NOTES § *Creating an item* → *Picking the parent epic* — with
  `--dependent-epic` naming that milestone's epic. A `blocked-by: <spec-ref>` blocker
  has no issue to check and is written as-is. Act on its `verdict`: `ok` → write the
  line; `cycle` → drop it and report the cycle; `drop-earlier` → drop it and report it;
  `pull-forward` → re-parent Y to `pullForwardEpic` with the note
  `milestone: M<k> (spec: M<j>) — pulled forward, required by #<item>`, then write the
  line. Exit `1` or `2` → leave the line unwritten and report it with the first stderr
  line. Ordering is settled here, never raised (`~/.claude/skills/kp-gh-lib/NOTES.md`
  § *When an item is human-gated*).
- **Board — create in one call.** A created item goes through
  `~/.claude/skills/kp-gh-lib/scripts/create-item.sh --repo <target-repo> --title "…"
  --body-file <body> --label … --project <owner>/<number> --origin <target-repo>#<n>
  --cache <scratchpad>/milestone-current-<owner>-<number>.json` plus the *Milestone*
  flags above; it adds the item to the resolved project. If the item is itself
  human-gated (`type:question` / `type:decision` / `type:conflict` / `type:research`),
  add `--assign-owner --priority top`: it is assigned to the project owner login and
  its `Priority` set to the board's top option. A `type:decision` whose every
  Recommendation is `confidence: high` is creator-decided
  (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Human-gated item body* → *Confidence and creator-decided items*): write
  its decision comment to `<scratchpad>/decided.md` with `__ISSUE__` and add
  `--decided-body-file <scratchpad>/decided.md`; the script then files it Ready. Exit `1`
  means nothing was created:
  report it. A reused item is not re-created; it is already on the board.

  Coding items are neither auto-assigned nor
  auto-prioritised. Assignees must be users; the script skips the assignee on an
  org-owned project, and the run reports that auto-assignment was skipped rather than
  failing. Prioritisation is best-effort: the script skips it when the board has no
  `Priority` field. Each `skipped` step in its JSON is noted in the report.

### 4.4 Reconcile the items that already reference this decision

Closing the decision changes what other items mean. **Both** branches of §4.2 run
this step — it is the difference between a resolution and a half-resolution.

1. **Find the referrers.** `~/.claude/skills/kp-gh-lib/scripts/find-marker.sh <target-repo>
   blocked-by <target-repo>#<n> --scope owner` — both the `blocked-by: #<n>` form in
   `<target-repo>` and the shared-board cross-repo form `blocked-by: <target-repo>#<n>`
   in the owner's other repos.
2. **Re-point them (Resolved branch).** An item blocked on the *decision* is really
   blocked on the *work the decision produced*. Re-point each referrer's
   `blocked-by:` line at the downstream item with
   `~/.claude/skills/kp-gh-lib/scripts/set-marker.sh <its-repo> <m> blocked-by --replace <target-repo>#<n>
   <downstream-ref>`, where `<downstream-ref>` is `#<new>` when both live in the same
   repo and `<owner>/<repo>#<new>` when they do not. Skip the edit when `<m>` **is** the
   downstream item (no self-edge), and check the new edge first with `edge-check.sh
   --project <owner>/<number> <its-repo>#<m> <downstream>`: `ok` → re-point it;
   `cycle` → leave the marker, drop the edge, and report it; `drop-earlier` → remove
   the line instead with `~/.claude/skills/kp-gh-lib/scripts/set-marker.sh <its-repo> <m> blocked-by --remove
   <target-repo>#<n>` (and report it); `pull-forward` → pull the downstream item forward
   to `pullForwardEpic` first, then re-point the edge; exit `1` or `2` → leave the
   marker and report it.
   Without this, closing `#<n>` makes every referrer look ready to
   `kp-do-gh-ready-items` §2.2 while the work they actually depend on is unbuilt.
3. **Clear them (Won't-do branch).** The decision produced no work, so the
   dependency is void: remove the `blocked-by: #<n>` line from each referrer with
   `~/.claude/skills/kp-gh-lib/scripts/set-marker.sh <its-repo> <m> blocked-by --remove <target-repo>#<n>` and say
   so in the report. Change nothing else about those items.
4. **Sweep the requirement's own orphans (Won't-do branch).** `~/.claude/skills/kp-gh-lib/scripts/find-marker.sh
   <target-repo> spec-ref <key>` for every ref the decision covers. Report each hit as a **close-candidate** with its number and
   title — the requirement is dropped, so the work is moot. **Never auto-close
   them**; the operator does. `kp-sync-spec-tasks` treats an implemented-but-still-open
   ref the same way.
5. **Report every item touched**, by number, with what changed on it. An item edited
   silently is an item nobody can audit.

### 4.5 Reflect the decision in the spec doc — this is the default

The decision issue exists **because** the spec text was ambiguous, underspecified, or
self-contradictory. Resolving it without amending that text leaves the spec
permanently wrong and, worse, undetectable: a later `kp-sync-spec-tasks` run sees a
closed decision plus a downstream item, classifies the ref as *Resolved*, and skips
it forever. Closing the issue is not the resolution; the amended spec is.

So apply the worktree/PR flow below **unless** the decision genuinely only routes
downstream work and leaves every sentence of the spec accurate as written. When you
skip it, the report and the close comment must carry the reason —
`no spec change: <why>` — never a bare "no spec change". When you do open a PR:

- Record `spec-pr: <url>` on the downstream item (outside the fence, with
  `~/.claude/skills/kp-gh-lib/scripts/set-marker.sh <downstream-repo> <new> spec-pr --add <url>`) and in the
  close comment, so `kp-sync-spec-tasks` can detect a decision whose spec PR never
  merged and re-surface the ref as **spec-drift**.
- **Gate the downstream item on the PR (Resolved branch).** Next to `spec-pr:`, outside
  the fence, write `blocked-by: <spec-repo>#<pr>` — always repo-qualified, since the PR
  lives in the spec repo — with `~/.claude/skills/kp-gh-lib/scripts/set-marker.sh <downstream-repo> <new>
  blocked-by --add <spec-repo>#<pr>`, which leaves an existing line alone. It lands before §4.7 starts
  the pr-loop, so no build loop runs the item against the old spec text its `spec-ref`
  points to. A PR has no milestone, so the edge is outside § *Milestone sequencing*
  (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Filing a follow-up item*), and it carries no
  `blocked-by:` of its own, so it cannot close a cycle. Referrers re-pointed in §4.4
  already wait through the downstream item and get no second edge. The Won't-do branch
  has no downstream item and writes no edge.
- **Who lifts the edge.** Once the PR merges, the close-out in `kp-gh-lib/scripts/pr-loop.sh`
  (`unblock-dependents.sh`) moves the item from `Blocked` to `Ready`. That script finds
  a dependent only in a repo owned by the spec repo's owner (a `user:<owner>` search),
  and moves it only from `Blocked`. A dependent it cannot reach stays in its column —
  a cross-owner one in `Blocked` waits for the operator to move it — but the launch gates
  (`kp-do-gh-ready-items` §2.2, `kp-do-gh-task-loop` §1.4.3) read the PR's state
  directly, so nothing builds it before the merge.
- The PR being *open* is not the spec being *updated*: the resolution is complete only
  once it merges. §4.7's fast path merges a clean spec PR here; any other goes to
  `kp-do-gh-pr-loop`, in its own headless session (§4.7). This skill never fixes it.

For a `type:conflict` spanning several docs, every doc the conflict names is edited
in the same branch and the same PR — a conflict resolved in one of two contradicting
documents is still a contradiction.

An item the spec fold makes owed beyond the §4.2 downstream item (a code-repo change the
amended text now requires) is filed per `~/.claude/skills/kp-gh-lib/NOTES.md`
§ *Filing a follow-up item*, never improvised. The report names its outcome: the filed
item, the human-gated item raised in its place, or `unfiled: check could not run —
<title> (exit <code>)`. An unfiled one also has that line posted as a comment on this
decision issue, so the issue is the durable record.

### 4.6 Close the decision issue

The close is the skill's own action — the PR only references the issue, it does not
auto-close it. Post the resolution comment **only if no prior "Resolved → " /
"Closed as won't-do" comment from this skill already exists** (check
`gh issue view <n> -R <target-repo> --json comments`):

- Resolved: `gh issue comment <n> -R <target-repo> --body "Resolved → created|reused #<new>[, PR <pr-url>][, no spec change: <why>]. Decision[ (agent-decided)]: <summary>. Re-pointed: <#m …|none>"`
  then `gh issue close <n> -R <target-repo> --reason completed`.
- Won't do: `gh issue comment <n> -R <target-repo> --body "Closed as won't-do[ (agent-decided)][, PR <pr-url>][, no spec change: <why>]: <summary>. Close-candidates: <#m …|none>"`
  then `gh issue close <n> -R <target-repo> --reason "not planned"`.

Include `(agent-decided)` exactly when the decision came from §3 (c).

Closing an already-closed issue is a harmless no-op.

### 4.7 Drive the spec PR to merged

Runs after §4.6, so the decision record is complete even if the loop runs long or stops
on a usage limit. It merges a clean PR itself (the fast path below) or launches exactly
one child, and either only when this run has a spec PR — a batch's one PR is driven once
for all its decisions (§ *Batch run* step 6) —
the one the worktree flow opened or reused, or the open `spec-pr:` a §4.1 re-run found.
With none — `no spec change: <why>`, not applied (no spec checkout), or push/PR creation
failed — launch nothing and say so in the report. With a spec PR, it still launches only
when §1 confirmed this session is the spec-repo primary checkout. `kp-do-gh-pr-loop` takes
its repo from the current checkout (its §0.2), so a launch from the target repo would
drive a different PR with the same number. A §4.1 re-run from any other checkout launches
nothing and reports **not driven — no spec checkout**, with
`/kp-resolve-spec-decision <n> --repo <target-repo>` to run from the spec-repo checkout.
`<pr>` is the number at the end of the
PR URL; `<project>` is the §1 project as `<owner>/<number>`.

**Fast path — a clean spec PR merges here.** Tried before the child launch below, and
only on the ordinary resolve branch of §4. It is never tried on the *Goal-answered branch*
(the issue carries `goal-ref:` outside the human-only fence), the *Audit-close branch*,
or a won't-do close (§4.2's Won't-do branch, from either branch): those PRs keep the full
review ⇄ fix loop, so go straight to the launch. Every step falls back to that launch,
unchanged, and the report names the trigger:

1. **Note `<checked-head>`** — `gh pr view <pr> -R <spec-repo> --json headRefOid -q
   .headRefOid`.
2. **One sonnet read.** Write its three inputs to the scratchpad, and nothing else: the
   diff (`gh pr diff <pr> -R <spec-repo> > <scratchpad>/spec-pr-<pr>.diff`), the decision
   text §3 selected (`<scratchpad>/spec-pr-<pr>-decision.md`, with `Write`), and each
   `spec-ref:` section at the head — a body of one `spec: <spec-repo>@<checked-head>:<path>#<anchor>`
   line per key, the file and anchor the *Spec-update worktree flow*'s step 1 maps it to,
   through `~/.claude/skills/kp-gh-lib/scripts/read-context.sh --body-file <body> --repo
   <spec-repo> > <scratchpad>/spec-pr-<pr>-sections.txt` (a non-zero exit falls back).
   Then one `Agent` call in the foreground, `subagent_type: Explore`, `model: sonnet`,
   told to read only those three files and answer, on its last line, exactly `ok` or
   `gap: <what differs>` to: "does each amended section say what the decision says, and
   nothing else?" A `gap:`, or any other answer, falls back.
3. **Check and approve — one call.**
   `~/.claude/skills/kp-gh-lib/scripts/spec-pr-fastmerge.sh <spec-repo> <pr> --decision
   <target-repo>#<n> --checked-head <checked-head> --key <key>… --read '<the read's last
   line>'`, one `--key` per `spec-ref` key, in one foreground `Bash` call with `timeout:
   600000` (`kp-gh-lib/SKILL.md` § *`spec-pr-fastmerge.sh`*). It waits for CI once, runs
   `spec-pr-check.sh`, re-reads the head and posts the approval verdict comment
   `guard_merge.py` reads, printing `approved <sha>`; any `fallback: <trigger>` line
   falls back, its trigger quoted in the report.
4. **Merge.** On `approved <sha>`, as its own `Bash` call:
   `gh pr merge <pr> -R <spec-repo> --squash --delete-branch`; a merge the API refuses
   falls back. Merged → the outcome is **merged**: launch nothing and go to §4.8.

`kp-do-gh-pr-loop` is `disable-model-invocation`, so the Skill tool cannot load it. Run
it as a headless child from the spec-repo primary checkout (§1) — the worktree is already
removed, and the pr-loop refuses to start inside one (its §0.2). The log `<log>` is
`<scratchpad>/spec-pr-loop-<spec-repo-name>-<pr>-<UTC yyyymmddThhmmss>.log` in the
session scratchpad directory: the timestamp gives every launch a fresh log, so an earlier
run's sentinel never ends the wait at once. Write it out as a literal path in every call,
since a shell variable set in one `Bash` call is gone in the next. Launch and wait on it
with `~/.claude/skills/kp-gh-lib/scripts/run-child.sh` — one launch call, then foreground
`--wait` calls (`Bash` `timeout: 540000`) re-issued until the child's result line
replaces `status: running`:

```bash
~/.claude/skills/kp-gh-lib/scripts/run-child.sh --log "<log>" --cwd "$PWD" --timeout-min 240 \
  -- "/kp-do-gh-pr-loop <pr> --project <project>"
~/.claude/skills/kp-gh-lib/scripts/run-child.sh --wait "<log>"
```

The script owns the detached launch, the family's standard flag set (`bypassPermissions`
among them, required as for every other headless child in the family: the loop reviews,
fixes, pushes and merges with no human present), the exit sentinel and the capacity grep.
**`--timeout-min 240` is a behaviour change:** the pr-loop used to run unbounded, and is
now killed after 240 minutes — a killed loop leaves its PR open, which the outcome below
reads as **parked** or **blocked**. **Never end the turn while the child is still
running**, and never reach for `run_in_background` or `Monitor`
(`~/.claude/skills/kp-gh-lib/NOTES.md` § *Waiting in a headless session*). The pr-loop
does its own board work; this step adds no Projects v2 call.

**Capacity check — before any GitHub read.** It is the `capacity=` field of the `--wait`
result line. The pr-loop quotes a child's limit line verbatim in its own report, so this
catches a limit hit anywhere inside the loop. Anything but `capacity=none` is a hit; keep
its `reset=` time if it has one, and the CLI's limit line from `<log>`, which the report
quotes verbatim.

**Spec PR outcome from GitHub, not the log** — the classification
`kp-resolve-spec-decision-auto` §4.4 uses. Run
`~/.claude/skills/kp-gh-lib/scripts/item-outcome.sh <spec-repo> --pr <pr>`
(`kp-gh-lib/SKILL.md` § *`item-outcome.sh`*), first match wins:

- `outcome=merged` → **merged**; go to §4.8;
- the capacity check is a hit → **capacity-limit**;
- `blocked-on-decision` → **blocked on decision #d**, `d` its `decision=`;
- `parked` → **parked**;
- `pr-closed` → **closed**;
- a non-zero exit → **parked**, with the script's stderr in the report — the PR is left
  as the loop left it, and the resume command below applies.

A non-zero child exit is not the outcome; GitHub state is. An unmerged outcome does not
undo the resolution: the decision stays closed, the downstream item keeps waiting on its
`blocked-by:` edge, and the report carries the log path and the resume command:
`/kp-resolve-spec-decision <n> --repo <target-repo>`, run from the spec-repo checkout,
drives the PR again (§4.1) **and** runs §4.8 on a merge. `/kp-do-gh-pr-loop <pr>` alone
merges the PR but skips §4.8, and once the PR is merged §4.1 only re-reports it, so the
items would never be synced.

### 4.8 Sync the items to the merged spec

Runs only when §4.7's outcome is **merged**. §4.2 amended the downstream item from the
decision before the spec PR was reviewed, and `kp-fix-pr` rounds inside the loop may have
reworded the spec since. Nothing else re-checks those items — `kp-sync-spec-tasks` never
edits a tracked item — so this step does.

1. **Read the merged text.** `gh pr diff <pr> -R <spec-repo>`, plus each file it touches
   as it now stands on the base branch: `git -C <spec-checkout> fetch origin --prune`,
   then `git -C <spec-checkout> show origin/<base>:<file>`, where `<spec-checkout>` is
   the §1 spec-repo checkout and `<base>` the PR's own base branch
   (`gh pr view <pr> -R <spec-repo> --json baseRefName -q .baseRefName`) — a §4.1
   re-run never runs the worktree flow that would otherwise define it.
2. **Collect the items to check:**
   - the downstream item (Resolved branch) and every referrer §4.4 re-pointed — on a
     §4.1 re-run, the ones the close comment lists under `Re-pointed:`;
   - for every other `spec-ref` whose requirement text the merged diff changed (mapped
     back to its key the way worktree flow step 1 maps a key to its heading), the open
     items carrying it: `~/.claude/skills/kp-gh-lib/scripts/find-marker.sh <target-repo> spec-ref
     <key>`.
3. **Compare and edit surgically.** Set each item's Scope and Acceptance criteria against
   the merged text. Where they differ, edit only the differing lines to say what merged
   (`gh issue edit <m> -R <its-repo> --body-file …`). Never rewrite a marker line
   (`spec-ref:`, `resolves:`, `blocked-by:`, `spec-pr:`, …), and leave an item that
   already matches untouched.

   A downstream item §4.2 created with the contract is also re-pinned. Its `spec:`
   lines and Rules attributions for the files the PR touched move to the merge commit
   (`gh pr view <pr> -R <spec-repo> --json mergeCommit -q .mergeCommit.oid`). Any short
   binding wording the decision fixed is quoted in Rules from the merged section. Run
   `lint-item.py` on the edited body before the edit, and fix every `FAIL` it reports.
   Some `FAIL`s the body cannot fix: a `spec-gap`, or a `context-resolve` on a section
   the PR removed or renamed with no replacement. These do not hold up the edit. Write
   the fixable part, add the `needs-contract` label
   (`gh label create needs-contract -R <its-repo> --color D93F0B --force`) and the reason
   comment NOTES § *Filing a follow-up item* defines (`<!-- kp-gh-lib:needs-contract
   -->`), and report `needs-contract #<m> — <FAIL line>`.
4. **Owed code.** Work the merged change newly makes owed is filed per
   `~/.claude/skills/kp-gh-lib/NOTES.md` § *Filing a follow-up item*, as §4.5 says,
   and reported as there: filed, raised, or unfiled (its line also posted on the
   decision issue).

On any unmerged outcome, edit nothing here, and say in the report that the items still
reflect the decision, not merged spec text.

### Goal-answered branch

A goal question's answer is a domain goal, not the technical decision
(`~/.claude/skills/kp-gh-lib/NOTES.md` § *Decision layers*). It is written into the
spec's goal section, and the original decision is restored for the next
`kp-resolve-spec-decision-auto` run to decide against the written goal. §3 is unchanged —
the operator answers the domain question — and so are §4.7 and the worktree flow's
mechanics. The rest of §4 changes:

- **§4.1–§4.3.** No downstream item is created or reused, and the `spec-ref` reuse search
  is skipped: the requirement's work stays with the original decision. A re-run on an
  issue that already carries a `Goal recorded → PR <pr-url>` comment amends nothing
  again: an open PR goes to §4.7, a `MERGED` one to the restore below, and a closed
  unmerged one is reported.
- **§4.4** does not run: the decisions waiting on this goal are cleared by the restore.
- **§4.5.** The spec PR amends the section the `goal-ref:` key names — mapped to its file
  and heading as worktree flow step 1 maps a `spec-ref`, or the brief's file and heading —
  not the `spec-ref` requirement, with the usual `<!-- decided in <owner>/<repo>#<n> -->`
  back-reference. It writes no `spec-pr:` or `blocked-by:` line, since there is no
  downstream item. A goal that is not written down is not answered, so
  `no spec change` does not apply; without a spec PR (no spec checkout, a failed push)
  nothing after §4.6 runs, and the report says so.
- **§4.6.** Do not close the issue. Post once: `Goal recorded → PR <pr-url>. Goal:
  <summary>`.
- **§4.8, on merged → restore**, in place of the item sync: the original decision's
  items were never changed. Each step checks before it acts, so a re-run finishes a
  partial restore.
  1. **Clear the waiting decisions** in every routed repo
     (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Before raising a human-gated item*, branch
     4, with `<target-repo>` as the item's repo), since an item in any of them may wait on
     this goal. Find the waiters with `~/.claude/skills/kp-gh-lib/scripts/find-marker.sh
     <target-repo> blocked-by '#<n>'`, plus `~/.claude/skills/kp-gh-lib/scripts/find-marker.sh
     <routed-repo> blocked-by <target-repo>#<n>` in each other routed repo, then remove
     each confirmed marker line — `~/.claude/skills/kp-gh-lib/scripts/set-marker.sh
     <its-repo> <m> blocked-by --remove <ref>`, `<ref>` the value `find-marker.sh`
     confirmed — from each open item
     that also carries a
     `<!-- kp-resolve-spec-decision-auto:waiting-on-goal -->` comment naming the same
     reference (`#<n>`, or `<target-repo>#<n>` from another repo): the goal it waited on
     is now written. Every other referrer keeps its edge, because this decision is still
     open.
  2. **Restore — one call:** `~/.claude/skills/kp-gh-lib/scripts/goal-question.sh restore
     --repo <target-repo> --issue <n> --pr-url <pr-url>`. It puts back the title and body
     from the latest escalation comment's verbatim block, with
     `goal-answered: <key> via <pr-url>` added after the block's last marker line — or,
     when it has none, after the human-only fence, else at the top (NOTES § *Goal
     questions*). The block carries no `goal-ref:` line, so that line is gone. It then
     swaps `type:question` for the escalation comment's `restore-type:` — `type:decision`
     when it has none, as on every `kp-resolve-spec-decision-auto` escalation, and no swap
     when that type is `type:question` — and posts once `Goal answered → PR <pr-url>;
     decision restored for the next /kp-resolve-spec-decision run.` under
     `<!-- kp-resolve-spec-decision:restored -->`. Exit `1` is a failed step, named in
     `skipped` or on stderr: report it, and a re-run finishes the restore.

  The issue stays open. On any unmerged outcome nothing is restored: the issue stays a
  goal question, and a re-run drives the PR again (above).
- **Won't do.** An answer that rules the requirement out drops it: take the Won't-do
  branch of §4.2 for the original requirement — §4.4 clears every `blocked-by: #<n>` and
  sweeps its orphans, §4.6 closes the issue as won't-do, and §4.8 syncs as usual — and the
  §4.5 spec PR also amends the goal section to record the new non-goal. Nothing is
  restored.

### Audit-close branch

An audit-close decision asks whether milestone M<k> may close with the findings of its
last audit still open. It changes no spec text and has no downstream item, so none of
§4.1–§4.8 runs; §3 is unchanged — only the operator's own words (a) or (b) decide it,
never a §3 (c) agent decision. Its outcome line is `no spec change: audit-close`. A
closed issue is a no-op, as in §4.1.

- **A — keep M<k> open until they are fixed.** Close the decision:
  `gh issue close <n> -R <target-repo> --reason completed`, with the §4.6 Resolved
  comment (`no spec change: audit-close. Decision: A — M<k> stays open until its findings
  are fixed`). The milestone gate opens once those items are closed; no further audit
  runs for M<k>.
- **B — move them to the next milestone.** One call, with every item the body lists and
  the project §1 resolved (`--project` → config `project`; omit it when there is none):

  `~/.claude/skills/kp-gh-lib/scripts/audit-close-move.sh --repo <target-repo> --issue <n>
  --milestone M<k> --spec-repo <spec-repo> --item <ref>… [--project <owner>/<number>]`

  It finds the next milestone's epic, re-parents each listed item still open in M<k> under
  it (its `blocked-by:` lines stay: an M<k> blocker is an earlier-milestone edge, which the
  gate satisfies), files the closed acceptance `type:audit` issue `Audit M<k> <date>`,
  closes the decision with the §4.6 Resolved comment (`no spec change: audit-close.
  Decision: B — moved <refs> to M<j>; audit #<a>`), and only then merges M<k>'s
  `release/M<k>` branches with `milestone-merge.sh` and, when that merge succeeded, tags
  M<k> (`kp-gh-lib/SKILL.md` § *`audit-close-move.sh`*). Each step checks before it acts, so a
  re-run finishes a partial one.

  **Run it detached with an exit sentinel.** The merge's CI wait alone can run to
  540 + 10 × (30 + 60) + 540 s per repo, past the 10-minute `Bash` cap, and a headless
  session that ends its turn mid-wait loses the merge and the tag. Launch it per
  `kp-gh-lib/NOTES.md` § *Waiting in a headless session*, with a fresh log `<log>` =
  `<scratchpad>/audit-close-move-<n>-<UTC yyyymmddThhmmss>.log` written out as a literal
  path in every call:

  ```bash
  nohup bash -c '~/.claude/skills/kp-gh-lib/scripts/audit-close-move.sh <args above> \
    > "<log>" 2>&1; echo $? > "<log>.exit"' >/dev/null 2>&1 & disown
  ```

  then wait in a foreground `Bash` call with `timeout: 540000`, re-issued until it prints
  the exit code — never `run_in_background` or `Monitor`:

  ```bash
  until [ -f "<log>.exit" ]; do sleep 5; done; echo "exit: $(cat "<log>.exit")"
  ```

  Its JSON is the last line of `<log>` (stderr shares the log), its exit code
  `<log>.exit`. Act on its output:
  - `{"target": null}` → post `No later milestone to move M<k>'s findings to — decide A or
    add one.`, leave the decision open and stop.
  - Otherwise the report takes `moved` and `already` as the items moved, `target` as M<j>
    and `audit`. The `merge` and `tag` lines go into the report. A non-zero `mergeExit`
    adds `milestone merge: failed — <first failed/conflict/ci line>` and `milestone tag:
    skipped (merge failed)` (`tag` is `"skipped"`); otherwise a non-zero `tagExit` adds
    `milestone tag: failed — <first failed line>`. A null `merge` reports `milestone
    merge: not checked (no project)` alongside `milestone tag: not checked (no
    project)`.
  - Exit `1` → report the step its stderr names and stop; a re-run finishes it.

  Option A adds no merge or tag call: M<k> is not done yet, and the audit that later
  closes it merges and tags it (`kp-audit-alignment` §8.4).

### No-spec-repo branch

In a project with no spec repo (§1), the decision is carried by the body of each coding
item it blocks instead of a spec PR. This branch replaces §4 for every number of such a
run; §2 and §3 run unchanged first. In order:

1. **Kinds.** It applies to a `type:decision` or `type:question` issue, and to a
   `type:conflict` issue — a reviewer/fixer disagreement on one finding, which
   `kp-do-gh-pr-loop-escalate` files as an `unactionable-finding` — when at least one of
   its `blocks:` lines (read outside the human-only fence and `<details>`) names, in the
   current checkout's `origin` repo, an issue labelled `type:coding` (open or closed) or
   a pull request (open or closed). Classify each such number with one
   `gh api repos/<repo>/issues/<m>` read: a response carrying a `pull_request` key is a
   pull request; otherwise it is an issue, with its `labels` and `state` from the same
   response. A `blocks:` line naming another repo is not classified — it qualifies
   nothing, and step 2 reports it `not folded: <repo>#<m> — no checkout`. Such a conflict
   runs every later step exactly as a `type:decision` does; one that qualifies but ends
   with no foldable target takes step 2's `blocks no open coding item` report and stays
   open, like a decision. A `type:conflict` whose `blocks:` lines name neither (no
   `blocks:` line, or only issues of other types or other repos), a `type:research`
   issue, or one carrying `goal-ref:` or `audit-close:` outside the human-only fence, is
   left open and reported `no-spec-repo: <target-repo>#<n> — <kind> needs a spec repo`.
2. **Targets.** The targets are the issues named by the decision's `blocks:` lines
   (`#<m>` or `<owner/repo>#<m>`), read outside the human-only fence and `<details>`,
   that are open and labelled `type:coding`. A `blocks:` line naming a pull request of
   the current checkout's `origin` repo resolves to the work item
   `~/.claude/skills/kp-gh-lib/scripts/linked-item.sh <repo> <pr>` prints as `issue` when
   its `via` is `closes` or `branch`; that issue is a target when it is open and labelled
   `type:coding`, counted once when a `blocks:` line also names it directly. A PR whose
   `issue` is null, or whose `via` is `spec-pr`, adds no target; a `linked-item.sh`
   exit 1 leaves the decision open and is reported `no-spec-repo: <target-repo>#<n> —
   linked-item.sh failed for #<pr>`. A pull request is never itself a target. This holds
   for every kind step 1 accepts. A target in a repo other than the current
   checkout's `origin` is not folded and is reported `not folded: <repo>#<m> — no
   checkout`. With no foldable target on a Resolved decision, the decision is left open
   and reported `no-spec-repo: <target-repo>#<n> blocks no open coding item`.
3. **Idempotency.** §4.1's CLOSED no-op applies unchanged (its `resolves: #<n>` search
   finds the targets). A target whose `### Context` already carries
   `decision: <target-repo>#<n>` was folded by an earlier run: it is not folded again,
   only re-checked as in step 4.
4. **Resolved — fold each target.** When this decision issue carries a held draft for
   the target — a `<!-- kp-gh-lib:held-draft -->` block in its body, raised by an
   earlier run of this step — the fold starts from that draft instead of the target's current body, as §4.2
   *Held draft* does for a created item, so the earlier decision's fold it carries
   reaches the target; then apply this decision's answers and check it as usual.
   Otherwise edit the target's body surgically, as §4.2 says for a reused item: amend only the Scope, Out of scope, Rules and Acceptance criteria lines
   the chosen option (with §3's expansion line) changes, each new criterion with its
   `— proof:`; add `decision: <target-repo>#<n>` under `### Context`; add a
   `resolves: #<n>` marker line outside the fence; append to the `For humans` line one
   sentence naming the decision and the chosen option. Check the edited body before
   `gh issue edit --body-file`:
   `~/.claude/skills/kp-gh-lib/scripts/lint-item.py --repo <its-repo> --body-file <draft>
   --code-root <root>`, with `<root>` the directory
   `~/.claude/skills/kp-gh-lib/scripts/fresh-checkout.sh <current checkout>` prints, then
   the cold reader: the stdout of `~/.claude/skills/kp-gh-lib/scripts/read-context.sh
   --code-root <root> --body-file <draft> --repo <its-repo>` is the only input of one fresh
   foreground read-only `Explore` agent with `model: sonnet`, which answers the six
   questions, both per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Coding item body* →
   *Cold-reader check*. A draft still failing after two repair rounds goes through NOTES
   § *Settling a failing draft*, with two differences because the coding item already
   exists: a pass edits the target instead of filing an item, and an open gap leaves the
   target's body unedited and the one human-gated item raised for it carries
   `blocks: #<m>` (the target) instead of that section's "No `blocks:` line" rule. A check
   that cannot run leaves the target unedited and the decision open, and is reported with
   that section's `unfiled: check could not run — <title> (exit <code>)` line.
5. **Resolved — referrers and close.** Once every foldable target was edited or held by a
   raised item, run §4.4 steps 1, 2 and 5 with the first target as the downstream item.
   Targets are excluded from the re-point step: each target's own
   `blocked-by: <target-repo>#<n>` line, if it has one, is removed with
   `~/.claude/skills/kp-gh-lib/scripts/set-marker.sh <its-repo> <m> blocked-by --remove <target-repo>#<n>`
   once its fold lands, so no target-to-target edge is written. Every non-target referrer
   is re-pointed to the first target only, its edge checked with `edge-check.sh` as §4.4
   step 2 says. Then close per §4.6's Resolved form, written as
   `Resolved → reused #<m>[, #<m2>…], no spec change: no spec repo — folded into the item body. Decision[ (agent-decided)]: <summary>. Re-pointed: <#r …|none>`,
   with a held target written `#<m> (held by #<q>)`.
6. **Won't do.** Edit no target body. Run §4.4 steps 1, 3 and 5, then close per §4.6's
   Won't-do form with `no spec change: no spec repo` and the targets listed under
   `Close-candidates:`. Targets are never auto-closed.
7. **No spec work.** §4.5, §4.7 and §4.8 do not run: no worktree, no spec PR, no
   pr-loop child.
8. **Report** per target: `folded <repo>#<m>` with the lint `INFO` line and the
   cold-reader result, `held <repo>#<m> by #<q>`, or `not folded <repo>#<m> — <reason>`.

### Batch run

Two or more numbers (§1) fold every answered decision into one spec branch and one spec
PR, drive that PR to merged once and sync every item after the merge. Each number keeps
its own target repo (§1), so every per-decision step below runs with that decision's own
`<target-repo>`. In this order:

1. **Read and split.** Run §2 and §3 for every number. An item leaves the batch and is
   resolved alone afterwards — the whole single-number procedure, in this same run, one at
   a time in the order given, its branch `spec/resolve-<n>` subject to the worktree flow's
   step 2 (prepare) reclaim / reuse rules unchanged — when any of these holds:
   - it carries `goal-ref:` (a goal question) or `audit-close:` (an audit-close decision)
     outside the human-only fence, or has a `goal-answered:` restore still to finish (§2);
   - it is labelled `type:conflict` or `type:research`;
   - its §3 decision is a won't-do / not-applicable outcome (§4.2's **Won't do / not
     applicable** — "won't do, drop it" or an equivalent answer that asks for no work).

   These are exactly the cases §4.7's fast path already skips (goal-question,
   audit-close and won't-do PRs keep the full review ⇄ fix loop), plus the conflict and
   research kinds and the closed re-run case below. An item that
   is already CLOSED (§4.1 no-op or supersession) also leaves the batch, but closed items
   are not run alone one by one: they are grouped by their `spec-pr:` link and each
   distinct open spec PR is driven once (step 8). An item §3 finds no decision for gets
   the §3 `no-decision` comment and report line and leaves the batch, but the run does
   **not** end its turn for it. When fewer than two items remain, the remainder runs as a
   single-number run. A no-spec-repo run (§1) does not batch: each number runs
   § *No-spec-repo branch* alone, in the order given.
2. **One branch, one worktree.** The *Spec-update worktree flow* runs once for the batch,
   through its step 2 (prepare) as `spec-branch.sh prepare --spec-repo <spec-repo> --issue
   <n1> --batch`, which names branch `spec/resolve-<n1>-batch` and worktree
   `../<repo-name>-spec-resolve-<n1>-batch` (`<n1>` the first number of the batch as given,
   after the split). Before naming it,
   look for an earlier batch: `gh pr list -R <spec-repo> --state open --json
   number,headRefName,body` — an open PR whose head matches `spec/resolve-*-batch` and
   whose body has a `## <owner/repo>#<n>:` section for any number in this batch has its
   branch and worktree name reused — prepare is passed the number in its head branch as
   `--issue` — so a re-run where some decisions closed meanwhile keeps the earlier PR.
   Step 2 (prepare)'s reclaim / reuse / stale-`MERGED`-branch rules apply to that name
   unchanged.
3. **One fold per decision.** For each batched decision in order: worktree flow step 1
   (map its `spec-ref` keys to files), step 3 (edit, surgically, with its own
   `<!-- decided in <owner>/<repo>#<n> -->` back-reference) and step 4 (commit: one commit
   `Resolve #<n>: <short decision>`). A decision whose fold fails — a `spec-ref` that maps
   to no file or heading, an edit that cannot be made, or a failed commit — has its
   uncommitted changes discarded (`git -C <worktree> restore --staged --worktree -- <its
   files>`), leaves the batch and is resolved alone afterwards (step 1's rule); it never
   stops the others. A decision whose §4.5 outcome is `no spec change: <why>` stays in the
   batch with no commit.
4. **One push, one PR.** Worktree flow step 5 (publish) once: `spec-branch.sh publish
   --spec-repo <spec-repo> --issue <m> --batch --title "Resolve <n1>, <n2>, …: <k>
   decisions" --body-file <file>`, which pushes, reuses an open PR on the branch or
   creates one. `<m>` is the same `--issue` number step 2 passed to prepare — `<n1>`, or
   the number from a reused earlier batch's head branch — so publish acts on the branch
   prepare set up. The body has one `## <owner/repo>#<n>: <short decision>` section per
   folded decision, each starting `Refs <owner/repo>#<n>.` followed by its summary.
   Publish removes the worktree. With no decision folded (all `no spec change`), publish
   is not run and the worktree is removed with `git -C . worktree remove <worktree>`;
   there is no PR and §4.7 launches nothing, as for a single decision.
5. **Per decision, unchanged:** the §4.1 searches, §4.2 (a created coding item pins the
   batch PR's head, as §4.2 *Pinned commit* says for one PR), §4.3, §4.4, §4.5's
   `spec-pr: <url>` and `blocked-by: <spec-repo>#<pr>` lines (the same batch PR on every
   downstream item) and the §4.6 close. A §4.2 `held:` decision stays open and is reported
   as for a single decision; its fold stays in the PR.
6. **§4.7 once for the PR.** Fast path step 3 runs `spec-pr-fastmerge.sh` once, with one
   `--decision <target-repo>#<n>` per folded decision in batch order, each with that
   decision's own target repo, and one `--key` per distinct `spec-ref` key of the folded
   decisions, grouped by decision in that same order; the script checks each decision in
   turn, and any failing check falls back. Step 2 is one sonnet read
   whose decision file holds every folded decision's text under its own `##
   <owner/repo>#<n>` heading, and whose sections file holds every `spec-ref` section of
   every folded decision; the agent answers `ok` or `gap: <owner/repo>#<n> <what
   differs>`. Step 3's approval, written by the script, carries one `Decision
   <target-repo>#<n> …` line per folded decision, in `--decision` order, then one
   `spec-ref:` line per key; step 4 merges as for a single decision. The fallback is one
   `kp-do-gh-pr-loop <pr>` child, as for a single decision.
7. **§4.8 once**, over the union of every folded decision's downstream item, re-pointed
   referrers and changed-`spec-ref` items.
8. **Re-run.** Running the same numbers again after a stop: §4.1 finds the closed
   decisions' shared `spec-pr:`; each **distinct** open spec PR is driven once (not once
   per decision), and §4.8 runs once on its merge for all of them.
9. **Report.** One §5 block per decision (source, downstream item, edges, reconciled
   items, close reason); one shared spec-PR block (URL, §4.7 outcome, and the resume
   command `/kp-resolve-spec-decision <owner/repo>#<n1> <owner/repo>#<n2> …` — qualified
   numbers, no `--repo` — run from the spec-repo checkout); the §4.8 sync list; and a
   `left the batch: <owner/repo>#<n> — <reason>` line for every item step 1 or 3 split
   out, with that item's own single-run report after it.

### Spec-update worktree flow

Runs in the **spec repo** resolved in §1 (`<spec-repo>`), never in the target repo
and never in the working tree in place. If §1 could not put you in a local spec-repo
checkout, stop here, complete the rest of the resolution, and report the spec change
as **not applied — no spec checkout**.

1. **Find the source file(s)** for each `spec-ref` the decision covers: discover the
   spec docs via config `specGlobs` (else `docs/specs/**/*.md`, `specs/**/*.md`,
   `SPEC*.md`), then map a `<doc-slug>#<heading-path-slug>` key back to its file and
   heading, or grep the docs for an explicit `REQ-*` id. A conflict yields more than
   one file — collect them all before branching.
2. **Prepare** the branch and worktree — one call, run from the spec-repo checkout:
   `~/.claude/skills/kp-gh-lib/scripts/spec-branch.sh prepare --spec-repo <spec-repo>
   --issue <n>`. `<worktree>` and `<base>` below are its output's `worktree` and `base`.
   It reclaims a leftover worktree (and the legacy `../spec-resolve-<n>` name), reuses an
   existing `spec/resolve-<n>` branch, and recreates that branch fresh when
   the newest PR on it is `MERGED` — a goal question's spec PR used the same branch, and a
   squash merge that did not delete it left it stale (`kp-gh-lib/SKILL.md`
   § *`spec-branch.sh`*).
3. **Edit the spec file(s) surgically** in the worktree to reflect the decision.
   Keep the `spec-ref` / heading identity intact so `kp-sync-spec-tasks` dedup
   still resolves the requirement. Leave a one-line back-reference beside the amended
   text — `<!-- decided in <owner>/<repo>#<n> -->` — so a human reading the spec can
   see which decision produced the wording, and a later run can trace it.
4. **Commit:** `git -C <worktree> add <file…>` then
   `git -C <worktree> commit -m "Resolve #<n>: <short decision>"`.
5. **Publish** (body references, does not auto-close, the issue). Write
   `Refs <owner>/<repo>#<n>. <summary>` to a file, then run
   `~/.claude/skills/kp-gh-lib/scripts/spec-branch.sh publish --spec-repo <spec-repo>
   --issue <n> --target-repo <owner>/<repo> --title "Resolve #<n>: <short>" --body-file
   <file>`. It pushes the branch, reuses an open PR on it or creates one against `<base>`,
   and removes the worktree. The decision issue lives in the **target** repo, so reference
   it in the qualified `<owner>/<repo>#<n>` form — a bare `#<n>` in the spec repo points at
   the wrong issue. Capture the printed `url` for the `spec-pr:` marker, the close
   comment, and the report.

If publish exits `1` (no remote, no write access), report it and still complete the
resolution (downstream item + reconciliation + close); the script has already removed
the worktree.

5. **Report.** Print:
   - target issue, target repo, spec repo, resolved project;
   - the decision read (quoted) **and its source** — existing issue comment,
     transcribed from this session (with the comment URL of the transcription), or
     agent-decided by the skill its `decision-source:` marker names (with its comment
     URL) — plus
     any supersession;
   - the downstream item: number, **created or reused**, type, `model:*` tier for a
     coding item, epic linked to (and whether a milestone epic was created for it) and its
     milestone line: the report line for the §4.3 *Milestone* script's output,
     `milestone: M<k>` for an item under an epic §4.3 chose, or the `placed … — unplaced`
     line, plus any `placed <owner/repo#r> under M<k> (chain had no milestone)` line, assignee and whether it was prioritised if
     human-gated, and for a created coding item its lint `INFO` line and cold-reader
     result (or the human-gated item raised instead, or the §4.2 `held: #<n>` line) — or
     "none";
   - `blocked-by` blockers recorded on it, and any dropped because they would have
     closed a cycle or pointed into an earlier milestone, plus every item pulled forward
     into an earlier milestone (with the milestone it left);
   - **items reconciled in §4.4**: every referrer re-pointed or cleared, and every
     close-candidate found, by number — or "none";
   - the spec PR: its URL and §4.7 outcome — merged (by the fast path, or by the loop
     with the fallback trigger that sent it there), blocked on decision #d, parked,
     closed, or capacity-limit with the reset time and the limit line quoted verbatim
     (as `kp-do-gh-pr-loop` §5 does, so a parent's `run-child.sh` capacity check sees it); for any
     unmerged outcome, also the log path and `/kp-resolve-spec-decision <n> --repo
     <target-repo>` (from the spec-repo checkout) as the resume that drives the PR and
     syncs the items — for a batch's PR, one resume with all its numbers (§ *Batch run*
     step 9) — noting that `/kp-do-gh-pr-loop <pr>` alone skips the §4.8 sync. Or,
     with no pr-loop launched, `no spec change: <why>`, "not applied — no spec checkout",
     "not driven — no spec checkout" with that same resume command, or the push/PR
     failure;
   - the `blocked-by: <spec-repo>#<pr>` edge written on the downstream item — or that it
     was already there, or why none was written (won't-do, no spec PR);
   - **items synced in §4.8**: every item edited, by number, with what changed — or
     "none"; after an unmerged outcome, that nothing was edited and the items still
     reflect the decision, not merged spec text;
   - for a goal question: the `goal-ref` key and the section amended, the
     `Goal recorded → PR` comment, and, on a merge, **restored** — title, body and
     restored type label back, the `goal-answered:` line written — with every waiting
     decision whose `blocked-by: #<n>` was cleared, by number; after an unmerged outcome,
     that nothing was restored; for a restore finished on a re-run, the steps it finished;
   - for an audit-close decision: the option, and on B the items moved, the milestone
     they moved to and the `type:audit` issue filed;
   - the close reason.

## Invariants

- A batch never blocks on one decision: an item that cannot be folded, or that the fast
  path skips, is resolved alone in the same run.
- **An audit-close decision touches no spec.** It is decided only by the operator; A
  only closes it, and B only moves the listed items to the next milestone and files the
  closed `type:audit` acceptance.
- **No spec repo, no spec PR.** In a project with no spec repo, a decision is carried by
  the body of each coding item it blocks, and closes only once each such body passed
  `lint-item.py` and the cold reader or is held by a raised item.

- Never close an issue that has no decision comment from §3. A decision stated in the
  session satisfies this **only once transcribed** — post the comment first, then act.
- **A goal question amends the goal, never the requirement, and stays open.** It creates
  no downstream item. Only a merged goal PR restores the original title and body — copied
  by `goal-question.sh restore` from the escalation comment, with `goal-answered:` added — and its type
  (`restore-type:`, else `type:decision`), and clears the edges of the decisions that
  waited on that goal. A won't-do answer is the one exception: it drops the requirement
  and closes the issue as won't-do.
- **Never author a decision, only transcribe or read one.** The operator's own words
  are the source, with one exception: a §3 (c) comment — one the operator delegated by
  running `kp-resolve-spec-decision-auto` or `kp-resolve-spec-research`, or one the
  creating skill posted at filing on a creator-decided item. This skill
  never writes one, and never treats
  the issue's Recommendation section or any other agent output as a decision.
- **Amending the spec is the default, not an option.** A resolution that leaves the
  ambiguous spec text standing is incomplete, and nothing downstream will ever
  re-detect it — so skipping it requires a stated reason, recorded on the issue.
- Never edit a spec doc in the working tree — spec changes go through an isolated
  worktree branch in the **spec repo** and a PR that references (does not
  auto-close) the decision issue. §4.7's fast path merges a clean one here, after
  `spec-pr-check.sh` and one bounded sonnet read, once `spec-pr-fastmerge.sh` has
  approved it; any other goes to `kp-do-gh-pr-loop`, in
  its own headless session. This skill never fixes a spec PR.
- **Never end the turn while the pr-loop child is still running** — detached launch,
  foreground wait on its sentinel, never `run_in_background` or `Monitor` (§4.7).
- **Items follow the spec text that merged.** A downstream item waits on its spec PR
  through `blocked-by:`; after the merge, it and the re-pointed referrers are synced
  surgically to the merged text, markers untouched. An unmerged spec PR edits nothing.
- **Closing the decision is not the end of the resolution.** Every item that
  referenced it — `blocked-by:` referrers, items sharing its `spec-ref` — is
  re-pointed, cleared, or reported as a close-candidate in the same run. Items are
  never auto-closed; that stays the operator's call.
- **Every marker search is a `find-marker.sh` call**, which quotes the phrase and
  confirms the exact marker line. An unquoted phrase makes GitHub parse the marker as a
  search qualifier and return a silently wrong set.
- Never alter the original `spec-ref` — it threads the requirement's lifecycle.
- `blocked-by` / `blocks` form one "must-complete-before" relation that MUST stay
  acyclic. Never write a `blocked-by` that points (directly or transitively) back
  at the item itself, and never both `resolves:` and `blocked-by:` the same issue.
- `blocked-by` / `blocks` edges stay inside one milestone
  (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Milestone sequencing*); an order problem is
  settled here and reported, per the same file's § *When an item is human-gated*.
- The downstream item and the closed decision issue share the `spec-ref`, so a later
  `kp-sync-spec-tasks` run sees the requirement as resolved and skips it — which is
  exactly why the `spec-pr:` marker must be recorded when a spec PR is opened.
- **One requirement, one tracking item.** Reuse an item that already carries the
  `spec-ref` instead of creating a sibling.
- **Re-running on an already-resolved (closed) decision is a no-op** that re-reports
  the existing downstream item / PR — never a second create, never a duplicate close
  comment, never a worktree/PR error (check-before-create throughout). The exceptions
  are an explicitly superseding decision and a still-open spec PR, which is driven
  again (§4.1).
