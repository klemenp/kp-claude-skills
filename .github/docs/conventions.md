# Conventions, long form

These are the long forms of the rules in `CLAUDE.md` § Conventions: which skill applies
each rule and where. The rules themselves are defined in `kp-gh-lib/NOTES.md`; this file
is the cross-skill map, and no skill loads it at run time.

## GitHub API budget in the `kp-*` GitHub skills

**GitHub API budget in the `kp-*` GitHub skills.** Projects v2 is the only expensive part
of the GitHub API here (GraphQL: 5,000 points/hr, cost scales with nodes returned). Do a
skill's whole setup with `kp-gh-lib/scripts/preamble.sh` (2–4 points normally, and it
calls the two below), resolve a board and find an issue's item with the 1-point
`kp-gh-lib/scripts/resolve-board.sh` and `item-id.sh`, move a merged item's dependents to
Ready with `unblock-dependents.sh`, find an item's milestone and apply the milestone gate
with `milestone-of.sh` / `milestone-gate.sh`, move an item's Status with the 1-point
`set-status.sh` (never `gh project item-edit`, which silently fails on Status), and post
token usage with `report-tokens.sh` — never paste those blocks back into a skill.

Never reintroduce `gh project field-list` (102 points) or a board-wide `gh project
item-list` (305 points / 582 KB on a 254-item board). `kp-do-gh-ready-items` is the one
skill that legitimately enumerates a whole board, and does it with `ready-sweep.sh`'s
narrow paginated query (3 points). The full rules and their rationale live in
`kp-gh-lib/NOTES.md`.

## Never end the turn while a started command is still running

**Never end the turn while a started command is still running.** A headless `claude -p`
child exits when its turn ends, so a backgrounded build or CI wait is lost and no commit,
PR or verdict lands. Builds, tests and CI polls wait in the foreground (detached +
sentinel past the 10-min cap) — never `run_in_background` or `Monitor` — and a `claude -p`
child is launched and waited on with `kp-gh-lib/scripts/run-child.sh`, which is that
pattern plus the capacity grep; an orchestrator with several children in flight waits on
each in turn (`kp-gh-lib/NOTES.md` § *Waiting in a headless session*).

An orchestrator's idle wait between sweeps uses the same foreground pattern, as a deadline
`until` loop: `kp-do-gh-ready-items` waits that way while work is pending, and ends when
nothing is pending or after `--idle-max` hours without a launch. The rules live in
`kp-gh-lib/NOTES.md` § *Waiting in a headless session*.

## Token usage: fork, model tier, subagents

**Token usage: fork, model tier, subagents.** Each `kp-*` skill is judged on its own
against three rules. **`context: fork`** only on a skill whose operator is never in the
loop mid-run, however it is launched; one that asks the operator or waits for steering
stays inline, and wanting visibility is not interaction. Anything a fork could change —
its own subagents, `report-tokens.sh`, a stdout or log line a caller parses, headless
foreground waits — is proven first with a throwaway probe skill in a scratch project's
`.claude/skills/` (never a new top-level directory here); a skill whose probe fails or was
not run stays inline.

Probed on Claude Code 2.1.270: `claude -p "/<forked-skill>"` waits for the fork and prints
its final reply as stdout, and a fork can wait in the foreground and launch subagents, but
its turns are written to `<session>/subagents/agent-*.jsonl`, which `report-tokens.sh`
reports in its `subagents` column, not in the top-level figures; how a fork surfaces the
CLI's usage-limit line or a `run_in_background` completion is unproven.

**`model:`** never on `kp-do-gh-task`, `kp-fix-pr` or `kp-review-gh-pr`, whose callers
pick the model from the item's `model:*` label — a tier that may carry an effort
(`model:opus-xhigh`), and `pr-loop.sh` never runs such an item's review below `high`;
elsewhere only to go cheaper, where the skill's own work fits the rubric in
`kp-gh-lib/NOTES.md` § *Creating an item* → *Model-tier rubric*, and never changing the
`--model` an orchestrator passes its children (a skill's `model:` overrides the CLI
`--model` while it runs — probed).

The four orchestrators, `kp-do-gh-ready-items`, `kp-do-gh-task-loop`, `kp-do-gh-pr-loop`
and `kp-do-gh-pr-loop-all`, carry `model: sonnet`, because their turns are almost all
`--wait` polls (781 sessions, 751M tokens, 22% of `kp-*` top-level usage from 2026-09-01
to 2026-10-09), while `kp-do-gh-task`, `kp-fix-pr` and `kp-review-gh-pr` still never carry
`model:`. **Effort:** probed on Claude Code 2.1.322 (2026-11-10), `claude -p … --effort
low` and `--effort xhigh` both succeed, while an unknown value only prints `Warning:
Unknown --effort value '<v>' — ignoring it and using the default effort` and the run
continues at the default — so `run-child.sh` validates `--effort` itself.

**Subagent phase:** a long skill's heavy read-only phase whose output later steps need
only in summary runs in one foreground, read-only `Explore` or `Plan` subagent that
returns a bounded summary (the `kp-check` §2 pattern); `Agent` is the only `allowed-tools`
addition it justifies, and `kp-review-gh-pr`'s independent pass is never summarised away.

## Pasteable prompts in a created issue body carry real values, not metavariables

**Pasteable prompts in a created issue body carry real values, not metavariables.** A
human-gated item carries a resolution prompt the operator is meant to copy and run, so it
must be runnable as it ships. Values known before creation (a PR number, a repo) are
substituted inline; the issue's **own** number is not known until `gh issue create`
returns, so write the body with a literal `__ISSUE__` token and `gh issue edit
--body-file` it away afterwards.

`kp-do-gh-task`, `kp-do-gh-pr-loop`, `kp-decompose-gh-task`, `kp-sync-spec-tasks`,
`kp-resolve-spec-decision` (§4.3, for a human-gated downstream item),
`kp-resolve-spec-research` (§4, for its research gate item, whose prompt names
`/kp-resolve-spec-research <research-n>`) and `kp-audit-alignment` (§7, for the decisions
it files) all emit such a line and does that post-create substitution — the recipe lives
in `kp-gh-lib/NOTES.md` § *Creating an item*, where the three creators point. It is
best-effort — a failed edit is noted, never fatal.

## Coding items carry their own contract

**Coding items carry their own contract.** Every `type:coding` issue follows
`kp-gh-lib/NOTES.md` § *Coding item body*. Builders and reviewers load context only
through `kp-gh-lib/scripts/read-context.sh`, never a whole spec doc; `lint-item.py` is the
test, and a body it fails is `needs-contract`. A downstream coding item
`kp-resolve-spec-decision` §4.2 creates (checked against its spec PR's head, so the
decision's own spec change counts), and a coding follow-up item, pass the same checks
before filing; a new coding draft that fails is settled, then raised — its gaps the code,
spec or Scope answer folded in, any open one raised as one human-gated item holding the
draft — never filed `needs-contract` (`kp-gh-lib/NOTES.md` § *Settling a failing draft*).

Items filed before the contract are converted by `/kp-backfill-contract` (§1), which
selects by that same lint, never touches an In progress or In review item, labels a failed
one `needs-contract` (raising one human-gated item, blocking it, for the gaps the code,
spec and its Scope leave open) and clears the label from one that now passes both the lint
and the cold reader. `kp-do-gh-ready-items` and `kp-do-gh-task-loop` launch nothing for an
item carrying that label and report it as `skipped: needs-contract`, and `kp-do-gh-task`
§1.2 runs the same lint on the body it is handed: a failing one is labelled, commented and
left unbuilt.

## Human-gated items are written for the operator

**Human-gated items are written for the operator.** Every `type:decision` /
`type:question` / `type:conflict` issue a skill creates takes its title and body from one
template: plain words, the question first, options described by observable effect, at most
three questions per item, and the agent's evidence in `<details>`. The template, rules and
a worked example live in `kp-gh-lib/NOTES.md` § *Human-gated item body*; the creators
point there and never restate a body shape.

`kp-do-gh-ready-items` §1.8 runs one batched headless `kp-resolve-spec-decision` for all
Ready `type:decision` / `type:question` items whose comments already hold an answer, which
folds them into one spec PR (in a project with no spec repo, into the body of each coding
item they block), before ordering its coding items; it skips every other human-gated item.

Every Recommendation names its confidence, and a `type:decision` whose every
Recommendation is `confidence: high` is **creator-decided**: the creating skill
(`kp-do-gh-task`, `kp-sync-spec-tasks`, `kp-decompose-gh-task`, `kp-resolve-spec-decision`
§4.3 or `kp-audit-alignment`) posts the agent-decided comment at filing through
`create-item.sh --decided-body-file`, the item lands Ready with no Telegram ping, and that
same §1.8 pass resolves it; a later human comment overrides it, and §1.8 pings only when
its resolve fails (`kp-gh-lib/NOTES.md` § *Human-gated item body* → *Confidence and
creator-decided items*).

`kp-resolve-spec-decision-auto` may answer a `type:decision` item itself when a fresh
subagent finds one option clearly best; its comment is marked agent-decided and a later
human comment overrides it. When no option is clearly best, it first climbs to the spec's
domain layer (`kp-gh-lib/NOTES.md` § *Decision layers*): a goal that settles the choice
decides it, and a goal the spec never states turns the item in place into a
`type:question` about that goal, which `kp-resolve-spec-decision` writes into the spec's
goal section before restoring the original decision.

Every skill that raises such an item climbs first (`kp-gh-lib/NOTES.md` § *Before raising
a human-gated item*): a goal the spec states is quoted in the Recommendation, and one it
never states is raised directly as that goal question, restored like an escalated one but
to the type it was drafted as; `kp-create-gh-item` asks the operator the goal-level
question instead. Every `kp-resolve-spec-decision` run, manual or auto, gates the
downstream item on the spec PR it opens with `blocked-by:`, drives that PR to merged with
a headless `kp-do-gh-pr-loop`, and syncs the items to the merged text.
`kp-resolve-spec-research` does a `type:research` item's research in a read-only,
Chrome-only subagent.

A conclusion becomes a marked findings comment, which a headless
`kp-resolve-spec-decision` resolves like an agent decision; each PR the research itself
opened (a live capture) then goes to a headless `kp-do-gh-pr-loop`, before each resulting
coding item goes to a headless `kp-do-gh-task-loop`. A question only the operator can
answer becomes a research gate `type:decision`, which `kp-resolve-spec-decision-auto` may
decide like any other; it then resumes the research with a headless
`kp-resolve-spec-research --chrome` child instead of resolving.

## Build order is the skills' call, and milestones run strictly in order

**Build order is the skills' call, and milestones run strictly in order.** Only technical
and feature unknowns, and the domain goals the spec leaves unwritten, become
`type:decision` / `type:question` / `type:conflict` items; which item comes first, which
milestone it lands in and a dependency cycle are settled by the skill and reported.
Milestones run M0, M1, … (numeric, so M9 before M10); no `blocked-by:` edge crosses
milestones (an earlier-milestone dependency is dropped, a later-milestone prerequisite is
pulled forward), and `kp-do-gh-ready-items` / `kp-do-gh-task-loop` launch nothing while an
earlier milestone has open work. In a project that uses milestones, every item a skill
creates is placed under a milestone epic per `kp-gh-lib/NOTES.md` § *Every new item has a
milestone*.

A milestone is done only once a `kp-audit-alignment` audit of it files nothing: both loops
run that audit as a headless child when its items are all closed, and after six rounds
that still file findings raise one `audit-close: M<k>` decision in the spec repo instead,
which only the operator resolves. A done milestone's `release/M<k>` branch is merged into
the default branch, and only then is it tagged `milestone/M<k>` on the default-branch HEAD
of every repo it spans, by the audit that closes it or by the audit-close decision's
option B. Until then each milestone item builds on and merges into `release/M<k>`, which
its first `kp-do-gh-task` build creates, and the merging skill closes its issue explicitly
(`kp-gh-lib/NOTES.md` § *Milestone branch*).

The rules live in `kp-gh-lib/NOTES.md` § *When an item is human-gated* and § *Milestone
sequencing*.
