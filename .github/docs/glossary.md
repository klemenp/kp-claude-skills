# Glossary

The words the skills and their notes use with a fixed meaning. Each entry ends with the
place that defines the term in full.

### operator

The one human who runs the skills, owns the board and answers what agents cannot. The
skills ping the operator only when something needs them.
See `kp-gh-lib/NOTES.md` § Operator notifications.

### human-gated item

An issue of type `type:decision`, `type:question` or `type:conflict`: work stops on it
until a human, or an agent that is entitled to, answers. It is written for the operator,
question first, with the agent's evidence folded away.
See `kp-gh-lib/NOTES.md` § Human-gated item body and § When an item is human-gated.

### human-only fence

A short plain-language summary at the top of every created issue, wrapped in
`<!-- human-only:start -->` and `<!-- human-only:end -->` comments. It is a reading aid
for people; agents strip it before reading the body.
See `kp-gh-lib/NOTES.md` § Human-only fence.

### marker line

A `key: value` line in an issue body, outside the fence, that scripts read as state:
`blocked-by: #12`, `parent: #3`, `spec-ref: REQ-…`, `blocks: …`.
See `kp-gh-lib/SKILL.md` § `scripts/find-marker.sh` and § `scripts/set-marker.sh`.

### coding-item contract

The fixed shape of a `type:coding` issue body (Goal, Scope, Out of scope, Context,
Acceptance criteria, Verify) from which an agent can build and review the item without
reading anything the body does not name.
See `kp-gh-lib/NOTES.md` § Coding item body.

### cold reader

A fresh subagent that is given only what a builder would be given for a draft item, and
answers whether it could build it without asking. A draft is filed only after it says yes.
See `kp-gh-lib/NOTES.md` § Coding item body → Cold-reader check.

### creator-decided

A decision item whose creator found one option clearly best, so it posted the answer
itself when filing; the item needs no operator unless a human comments later.
See `kp-gh-lib/NOTES.md` § Human-gated item body → Confidence and creator-decided items.

### agent-decided

A decision answered by `kp-resolve-spec-decision-auto` in a marked comment. A later
human comment always overrides it.
See `kp-resolve-spec-decision-auto/SKILL.md`.

### decision layers

The order in which a choice is settled: domain goals drive feature decisions, and
feature decisions drive technical ones. A decision its own layer cannot settle is
"climbed" to the layer above before anyone is asked.
See `kp-gh-lib/NOTES.md` § Decision layers.

### goal question

A question about a business or domain goal the spec never states, raised in place of the
technical decision that turns on it. Its answer is written into the spec's goals first.
See `kp-gh-lib/NOTES.md` § Human-gated item body → Goal questions.

### milestone epic

The `type:epic` issue that groups one roadmap milestone (`M0`, `M1`, …). Milestones are
built strictly in order, and every new item is placed under one.
See `kp-gh-lib/NOTES.md` § Milestone sequencing.

### release branch

`release/M<k>`: the branch a milestone's items build on and merge into. It reaches the
default branch only once the milestone's audit files nothing.
See `kp-gh-lib/NOTES.md` § Milestone sequencing → Milestone branch.

### verdict

The marked comment a review ends with: `verdict: APPROVED` pinned to the head commit, or
`verdict: REQUEST_CHANGES` with findings. The merge gate and the PR loop read it.
See `kp-review-gh-pr/SKILL.md` §6 and `CLAUDE.md` § Enforcement.

### park

To stop driving a PR and leave it open with a reason (a blocking decision, a merge that
is blocked, a loop that stopped converging), so a later run can pick it up.
See `kp-do-gh-pr-loop/SKILL.md`.

### sweep

One pass over a whole board by `kp-do-gh-ready-items`: read every Ready item cheaply,
launch what can be built, wait, and look again.
See `kp-do-gh-ready-items/SKILL.md` and `kp-gh-lib/SKILL.md` § `scripts/ready-sweep.sh`.

### needs-contract

The label on a coding item whose body does not meet the contract. Nothing builds it
until `kp-backfill-contract` converts it.
See `kp-gh-lib/NOTES.md` § Coding item body.

### headless child

A `claude -p` process an orchestrator launches for one step and waits on. It has no
human attached and exits when its turn ends.
See `kp-gh-lib/NOTES.md` § Waiting in a headless session and `kp-gh-lib/scripts/run-child.sh`.
