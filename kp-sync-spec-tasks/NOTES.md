# Implementation notes — kp-sync-spec-tasks / kp-resolve-spec-decision

Design rationale and the runtime decisions the skills must make. Read this
before editing either skill.

## Sub-issue (parent/child) mechanism

Detected at runtime, in the order `~/.claude/skills/kp-gh-lib/NOTES.md` § *Creating an
item* → *Sub-issue linking* fixes.

### The `gh api` breadth tradeoff

`allowed-tools` grants `Bash(gh api:*)`, which is **broad** — `gh api` can reach
any REST/GraphQL endpoint, not just sub-issue mutations. We accept this because
sub-issue linking has no narrower stable CLI surface across versions, and the
skill is `disable-model-invocation: true` (manual-only) and forked, so the grant
is exercised only on explicit user invocation. If your environment needs tighter
scoping, replace `Bash(gh api:*)` with a wrapper script that whitelists only the
`addSubIssue` mutation and node-id lookups, and grant `Bash(<wrapper>:*)` instead.

`kp-resolve-spec-decision` carries the same tradeoff for `Bash(git -C:*)`. Its spec
edits happen in a **worktree** (`../<repo-name>-spec-resolve-<n>`), so every git call is
`git -C <worktree> …` — which the narrower `Bash(git add:*)` / `Bash(git commit:*)`
/ `Bash(git push:*)` prefixes do not match, since the command starts `git -C`. The
broad grant is accepted for the same reasons (manual-only, one issue at a time);
tighten it with a wrapper if your environment needs to. `kp-sync-spec-tasks` carries it
too: a routed ref's clone is fetched and read with `git -C <path> fetch` / `grep` /
`show` (SKILL.md §0.9, §3).

## Model-tier label (`model:*`) on coding items

Every `type:coding` item the family creates carries exactly one `model:*` label, per the
one rubric in `~/.claude/skills/kp-gh-lib/NOTES.md` § *Creating an item* → *Model-tier
rubric*; its colors are in *Labels* there.

## Why `kp-sync-spec-tasks` forks but `kp-resolve-spec-decision` does not

- **`kp-sync-spec-tasks` is `context: fork`.** Its operator is never in the loop
  mid-run — a missing input stops the run rather than waiting for an answer. It is a
  bulk, read-heavy classifier that lists many issues, so forking isolates that
  transient context from the main conversation and lets it run as a clean,
  repeatable batch. The headless `while NEW_ISSUES=0` loop still works: probed on
  Claude Code 2.1.270, `claude -p "/<forked-skill>"` exits only after the fork
  finishes and prints the fork's own final reply as stdout, final line last. Inside
  the fork, SKILL.md §3's codebase search runs in one read-only `Explore` subagent
  that returns one verdict line per ref, so the grep output never sits in the fork's
  context through §5's creates.

- **`kp-resolve-spec-decision` runs inline (no fork).** Its own SKILL.md intro says why.

## Blocker markers (`blocked-by:` / `blocks:`) and acyclicity

Dependencies between items are recorded from both ends so either issue is
self-describing:

- A human-gated issue declares `blocks: <key>` (forward): resolving it unblocks
  requirement `<key>`. This already existed.
- Every created item declares `blocked-by: #<n>` (or `blocked-by: <spec-ref>` when
  the blocker is not yet tracked) for each issue that must complete before it.
  This is the new inverse marker, added by both skills at create time. Omit the
  line entirely when an item has no blockers — absence means "ready".

Both directions describe **one** "must-complete-before" relation, which stays acyclic
and inside one milestone per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Milestone
sequencing* (its *Acyclicity* walk, then its edge rules).

Sources of blockers `kp-sync-spec-tasks` considers when creating an item for ref `R`:
open human-gated issues carrying `blocks: R`, and prerequisite requirements `R`'s
spec text declares a dependency on. `kp-resolve-spec-decision` additionally carries
forward any blocker the resolved decision still leaves outstanding.

Note: a requirement with an *open* human-gated blocker is classified BLOCKED in
SKILL.md §2.1 and gets no coding issue at all, so in practice a created coding
item's `blocked-by` edges come from cross-requirement prerequisites, not its own
decision issue.

### Re-pointing edges when a decision resolves

An edge that points at a decision issue is a **placeholder**: the dependent item is
not really waiting on the *decision*, it is waiting on the *work the decision has
yet to name*. So when `kp-resolve-spec-decision` closes decision `#n` and produces
downstream item `#new`, it rewrites every open `blocked-by: #n` to
`blocked-by: #new` (qualified `<owner>/<repo>#new` across repos) — its §4.4. Skipping that step
is silently unsafe rather than merely untidy: `kp-do-gh-ready-items` §2.2 resolves a
blocker by **reading its state**, so a closed-but-unreplaced `#n` reads as satisfied
and the dependent item is dispatched while its real prerequisite is unbuilt.
Re-pointing never crosses milestones: when the new target sits in another milestone, the
edge follows `~/.claude/skills/kp-gh-lib/NOTES.md` § *Milestone sequencing* instead.

On a won't-do resolution there is no `#new`, so the edge is void: the marker is
removed outright, and any open item still carrying the dropped requirement's
`spec-ref` is reported as a **close-candidate** — never auto-closed, matching
SKILL.md §2.4.

## Dedup vs. cache — keep them separate

- **`spec-ref` on GitHub is the only dedup authority.** Always re-query GitHub
  (`~/.claude/skills/kp-gh-lib/scripts/find-marker.sh <repo> spec-ref <key> --state all`)
  before creating. It quotes the whole phrase — bare `spec-ref:<key>` parses as an
  unknown qualifier and always returns empty, silently defeating dedup.
- **`.claude/spec-sync-cache.json` is advisory only** — it memoizes the
  expensive implementation-detection verdict keyed by `spec-ref` + the git SHA.
  It is safe to delete at any time; deleting it only forces re-evaluation.
- One `spec-ref` may map to several issues across its lifecycle (a decision
  issue, then the coding issue that `resolves:` it). The per-ref decision logic
  in SKILL.md §2 prevents double-tasking a single requirement across types.

## Target repository & repo bootstrap

Issues describe implementation work, so they belong in the repo where that work is
built — the **app/service repo**, not the spec repo the skills run in. Both skills
resolve a `<target-repo>` at runtime (`--repo` argument → config `targetRepo` →
else ask; `kp-resolve-spec-decision` can also read it from an `owner/repo#n` issue
reference) and pass `-R <target-repo>` to every `gh issue`/`gh label` call. The
skills never default to the spec repo. `epicMapping` overrides may carry a per-doc
`repo` so different epics fan out to the repos that own them.

**Routing a requirement by area.** One spec can cover several repos inside a single
H1 (`shop-spec/TECH_SPEC.md` covers both `shop-api` and `shop-app`), which an
`epicMapping` override cannot split. `kp-sync-spec-tasks` therefore resolves a repo per
`spec-ref`, first match wins: `requirementRepos[<AREA>]` (the `<AREA>` of
`REQ-<AREA>-<nnn>`; a derived heading-path key never matches) → `epicMapping` override
`repo` → `--repo` / `targetRepo`. That ref's repo replaces the target repo for its
dedup, classification, creation, labels, repo code and board add. Dedup searches the
target repo as well whenever the two differ, so items filed before the routing entry
existed are still found. A routed repo's code lives in another checkout, so each entry
names a local clone `path`. Before classifying, the skill checks that the path is a
work tree whose `origin` is the configured repo and fetches it, then detects code
against `origin/release/M<k>` (the current milestone's branch) when that origin has it,
else `origin/<default branch>`, instead of the working tree, so a stale local branch
never hides merged work. A bad path or a failed fetch stops the run before anything is
created.

The spec repo is decoupled from the work repo on purpose: one spec repo can drive
many service repos, and the spec docs / `spec-ref` identities stay stable even as
the implementation repos churn. The Project (v2) board is the cross-repo join —
Projects v2 hold issues from any repo, so `gh project item-add` works regardless of
where each issue was filed. The spec-update worktree/PR flow in
`kp-resolve-spec-decision` is the one thing that stays in the spec repo, because it
edits the spec docs themselves.

**Bootstrap when the target repo does not exist.** `kp-sync-spec-tasks` probes
`gh repo view <owner/name>`. If the repo is absent it creates **exactly one**
bootstrap issue — a `type:coding` "create the repository" task with the stable
`spec-ref: repo-bootstrap:<owner/name>` — and this is the *only* item either skill
may ever create in the spec repo. No other items are created that run (they would
have nowhere to live); they are reported as blocked-on-repo-bootstrap and created
on a later run once the repo exists. The bootstrap issue dedups against the spec
repo so it is created once; everything else dedups against the target repo.

## Target project resolution & owner assignment

Both skills attach created issues to a GitHub Project (v2). The project is
resolved at runtime in a fixed order — `--project` argument → config
`.claude/spec-sync.json` `project` → else **ask the user**, listing candidates
with `gh project list` (repo owner and `@me`). Never invent or default a project;
if it cannot be resolved and the user is not prompted, stop.

Human-gated items (`type:decision` / `type:question` / `type:conflict` /
`type:research`) are auto-assigned to the project **owner login** at creation so
the person responsible for the board is the one prompted to resolve them. Coding
and epic items are left unassigned. GitHub assignees must be users, so an
org-owned project's owner is not assignable — in that case report that
auto-assignment was skipped rather than failing the run.

## Resolution flow (audit trail)

Decision/question/conflict issues are deliberately **async and human-gated**:
the binding decision is a GitHub comment, which is auditable and attributable —
the human's, the marked agent decision `kp-resolve-spec-decision-auto` posts on a
`type:decision` item when the operator runs it and one option is clearly best, or the
one the creating skill posts at filing when every Recommendation is high-confidence.
`kp-sync-spec-tasks` never resolves them; it only creates them and then treats an open
one as BLOCKED. `kp-resolve-spec-decision` reads the latest decision comment (a later
human decision supersedes an agent decision), lands the downstream item carrying the
same `spec-ref` plus `resolves: #<n>`, and closes the decision issue with an outcome
comment. If no decision comment exists yet, it prints what is needed and stops — it
never guesses.

**One requirement, one tracking item.** The downstream item is *created or reused*:
before creating anything, the skill searches both `"resolves: #<n>"` and
`"spec-ref: <key>"` (state `all`). A requirement often already has an item — one
filed before the ambiguity surfaced, or a prior round's — and the right move is to
edit that item to carry the decision, not to file a sibling beside it. Both searches
quote the whole phrase and are confirmed by reading the body: unquoted, GitHub
parses `resolves:`/`spec-ref:` as a search qualifier and returns a wrong set, and
"reuse the number you found" against a wrong hit is worse than a duplicate.

**Closing the decision is not the end of the resolution.** Everything that pointed
at the decision has to be reconciled in the same run — the `blocked-by:` referrers
above, and the spec text below. A run that closes the issue and stops there leaves
the board and the spec disagreeing with the decision, with nothing downstream able
to notice.

### Reflecting a decision back into the spec

`kp-resolve-spec-decision` edits the spec doc on an **isolated git worktree branch**
(`spec/resolve-<n>`), commits, pushes, and opens a PR. The skill never edits the
working tree in place, so the operator's checkout is untouched. The PR uses
`Refs <owner>/<repo>#<n>` (a mention) rather than `Closes`: the skill closes the
decision issue itself as its own auditable action, so an auto-closing PR would be
redundant and would misattribute the resolution to the merge. The reference is
**qualified** because the decision issue lives in the target repo while the PR is
in the spec repo — a bare `#<n>` there points at an unrelated issue. The spec edit
keeps the `spec-ref`/heading identity intact so a later `kp-sync-spec-tasks` run still
dedups the requirement, and leaves a `<!-- decided in <owner>/<repo>#<n> -->`
back-reference beside the amended text.

**The spec amendment is the default, not an option.** The decision issue exists
because the spec text was ambiguous, underspecified, or self-contradictory; a
resolution that leaves that text standing has fixed the board and not the source of
truth. Worse, nothing re-detects it: SKILL.md §2 classifies the ref as *Resolved*
(closed decision + downstream item) and skips it on every future run. So skipping
the amendment requires a stated reason — `no spec change: <why>`, recorded in the
close comment — and never a bare "no spec change". A `type:conflict` amends **every**
doc it names in one branch and one PR; a contradiction fixed on one side is still a
contradiction.

**An open PR is not an updated spec.** The skill opens the PR and closes the issue
in the same run, so between those two moments the decision reads as done while the
spec still says the old thing. Two things keep that visible: the skill records
`spec-pr: <url>` on the downstream item and reports the PR as unmerged, and
`kp-sync-spec-tasks` §2.3 reads that marker's PR state on every later run and reports
the ref as **spec-drift** until it merges. Neither skill merges it — that stays the
operator's action.

**Which repo the worktree flow runs in.** The spec docs are in the spec repo while
the decision issue is in the target repo, so the flow resolves a `<spec-repo>`
explicitly (`--spec-repo` → config `specRepo` → the current checkout if it actually
holds spec docs → else ask) and requires a **local primary checkout** of it. Every
`gh pr` call is pinned with `-R <spec-repo>`; unpinned, they silently follow the
session's cwd and would branch off whichever repo the operator happened to be in.
When no spec checkout is available the flow is skipped and reported as *not applied*
— the rest of the resolution still completes.

PR/push failures (no remote, no write access) are reported but do not block the
resolution (downstream item + reconciliation + issue close still happen); the
worktree is removed either way.
