---
name: kp-gh-lib
description: Helper library, not a command — shell scripts the kp-* GitHub skills call to run the shared setup preamble, to resolve a board's Status/Priority fields, find an issue's item on that board, look up an issue's milestone and apply the milestone gate, check a dependency edge, unblock a merged item's dependents, find the issues carrying a marker line, split, reassemble and check an issue body's fence and marker parts, strip its fence, run a new item's whole create chain, handle goal questions, move a board item's Status, upsert a token-usage comment, read a PR's latest review verdict and fix summary, decide a re-review's scope and item-body hash, add a research item's PRs to the board, launch and await a headless claude -p child, drive one PR's review ⇄ fix loop (pr-loop.sh), index a spec repo's sections, give a fresh origin checkout, resolve, clone and guard a repo's primary checkout, validate a spec repo's routed clones and pin its spec commit, print a coding item's bounded context, and lint a draft coding item.
disable-model-invocation: true
---

# kp-gh-lib — shared scripts for the kp-* GitHub skills

Not a skill to run. It sits at the top level only because this repository is
`~/.claude/skills`, where every directory is a skill candidate. The kp-* GitHub skills call
these scripts by absolute path (`~/.claude/skills/kp-gh-lib/scripts/<name>`) rather than
each carrying its own copy of the same GraphQL queries and token sum.

Every script is bash plus stdlib `python3`, prints usage and exits `2` on bad arguments,
and exits non-zero on failure. A wrapper's Python program lives beside it in
`scripts/py/` (`pr-loop.sh` runs `scripts/py/pr_loop.py`), never inside the shell file. Results go to stdout, diagnostics to stderr. The GitHub API
budget rules these scripts exist to honour, and their rationale, are in `NOTES.md`.

## `scripts/preamble.sh`

`preamble.sh (--issue <n> | --pr <n> | --no-item) [--project <number|owner/number|id>] [--no-fetch]`
— the one setup preamble the `kp-*` GitHub skills share, run from inside the target
checkout: repo and auth guard, `git fetch origin --prune` (plus a pull of the current
branch when the tree is clean), project resolve, board fields via `resolve-board.sh`, and
the work item's id via `item-id.sh`. Normally **2** GraphQL points on `--no-item`, **3** on
`--issue` and **4** on `--pr`, plus one each for a `PVT_…` node-id `--project`, an issue that has to be added
to the board, and an organization-owned board (`resolve-board.sh` tries `user(login:)`
first) — so 5 on the common paths and 6–7 where those add up. Never `gh project
field-list` or a board-wide `gh project item-list`.

```json
{"repo": "owner/name", "defaultBranch": "main",
 "project": {"owner": "example-org", "number": 4, "id": "PVT_…", "ownerType": "user"},
 "status":   {"fieldId": "PVTSSF_…", "options": {"Ready": "61e4505c", "…": "…"}},
 "priority": {"fieldId": "PVTSSF_…", "options": {"P0": "79628723"}, "top": "79628723"},
 "issue": 89, "itemId": "PVTI_…", "itemStatus": "Ready",
 "pr": {"number": 112, "head": "task/89-preamble-sh", "headSha": "…",
        "base": "main", "isDraft": false, "state": "OPEN"}}
```

Unlike `resolve-board.sh`, `status` and `priority` map option **name → id** — what a
caller naming `In progress` actually wants — and `priority.top` is the highest-priority
option (board order puts it first). `itemStatus` is the item's current Status, which saves
a caller a redundant write when it already matches the one it was going to set. A field
the board lacks is `null`, and an option a board names differently is simply absent: both
are the caller's cue to **ask the operator which options map to the states it needs**, or
to skip that write as best-effort if it can.

The project is resolved from `--project` → the repo's `.claude/spec-sync.json` `project`
→ else exit `6`; the script itself never prompts. An issue not on the board is added with
the `addProjectV2ItemById` mutation — never `gh project item-add`, which costs 4 points —
and the mutation's response carries the new item's id, so `itemId` comes back non-null
with `itemStatus` `null`: a freshly added item has no Status, and nothing is looked up
again.

With `--pr`, the linked issue is the PR's **first closing reference** (`Closes #n`). GitHub
leaves that field empty on a PR whose base is not the default branch (a `release/M<k>`
PR, `NOTES.md` § *Milestone branch*), so then the first closing keyword in the PR body
is used instead. A PR that closes none leaves `issue`, `itemId` and `itemStatus` `null` — not an error; the
caller decides what that means. `--no-fetch` skips the git sync, for a caller that has
already synced.

`--no-item` is for a caller that needs the repo, project and board fields but no single
work item — a creator such as `kp-create-gh-item`, `kp-backfill-contract` or
`kp-decompose-gh-task`. It runs the guard, sync, project resolve and board lookup
unchanged and skips the PR read, the item lookup and the add: `issue`, `itemId`,
`itemStatus` and `pr` come back `null`, and it never adds anything to the board.

**The board is best-effort; the repo and the PR are not.** A Projects v2 failure —
the board unresolvable, the item lookup or the add failing — warns on stderr and nulls
`project.id`, `status`, `priority`, `itemId` and `itemStatus`, and the run still exits
`0` with everything else filled. A caller reads those nulls the same way it reads a field
the board lacks: **note the miss and skip this run's board writes**, never abandon the
work. A board glitch must not block a verdict, a fix push, a merge or a loop cycle.
Failing to read the repo or the PR leaves nothing to work on and is fatal.

Exits, and what a caller does with each: `0` ok · `6` project unresolved, candidates on
stderr → **ask** the operator which project and re-run with `--project` · `5` repo guard
or auth, `2` usage, `1` a GitHub failure that left nothing to work on → **stop** and
report the message.

Every `gh` call a calling skill makes, this one included, obeys `NOTES.md`
§ *GitHub API budget*.

## `scripts/resolve-board.sh`

`resolve-board.sh <owner> <number>` — the board's node id, whether its owner is a user or
an organization, and its `Status` and `Priority` single-select fields:

```json
{"projectId": "PVT_…", "ownerType": "user",
 "status":   {"fieldId": "PVTSSF_…", "options": [{"id": "47fc9ee4", "name": "In progress"}, …]},
 "priority": {"fieldId": "PVTSSF_…", "options": [{"id": "79628723", "name": "P0"}, …]}}
```

Options keep board order, so the top-listed `Priority` option comes first. A field the
board lacks is `null`. One 1-point query; a user-login miss retries once as an
organization (1 more point), and `ownerType: "organization"` tells the caller the owner
login is not an assignable user.

## `scripts/ready-sweep.sh`

`ready-sweep.sh --project <owner>/<number> [--repo <owner/name>] [--only <#,#,…>]
[--label <name>] [--status <name>]` — the board sweep `kp-do-gh-ready-items` §1 runs:
one line per selected item, so the skill reads a handful of lines instead of the board
JSON and every body. It keeps OPEN issues in Status `--status` (default `Ready`) carrying
`type:coding` or a human-gated type, narrowed by `--repo`, `--only` (`#n`, `n`, `name#n`
or `owner/name#n`) and `--label`. Lines sort by kind in this order, then repo, then
number:

```
ambiguous #7 | o/a, o/b
item o/a#8 | [X] Item 8 | sonnet | #3, other/b#9 | none
gated o/s#4 | [X] Item 4 | type:decision | check:answered-agent
needs-contract o/a#1 | [X] Item 1
```

An `item` line carries the model alias (`opus (no model label)` without one), the
`blocked-by:` markers outside the human-only fence (`none` without any) and a repo-label
or title-prefix mismatch (`none` without one). A `gated` line's fourth field is
`answered-agent`, `answered-person`, `unanswered` or `-` (conflict, research), read with
`decision-state.sh`; `check:<fallback>` means human comments follow the latest decision,
and whether one picks an outcome is the caller's judgment — `<fallback>` is the state if
none does.

Cost: one narrow paginated GraphQL query (3 points on a 254-item board; a user-login miss
retries once as an organization, 1 more), then one `gh issue view` (1 point) per survivor
of the sweep's own filters only, and REST-only `decision-state.sh` reads. Exit `0` swept
(no lines is a valid result), `1` a GitHub call failed (stdout empty, one stderr line),
`2` bad arguments. Offline fixtures: `kp-gh-lib/tests/ready-sweep/run.sh`.

## `scripts/item-id.sh`

`item-id.sh <owner/repo> <issue> <project-id>` — the issue's item on that board, looked up
from the issue side in one 1-point query:

```json
{"itemId": "PVTI_…", "status": "Ready", "statusOptionId": "61e4505c", "contentId": "I_…"}
```

`itemId` is `null` when the issue is not on the board; `status` is `null` when the item
has no Status. `contentId` is the issue's own node id — what a caller adding it to the
board passes to `addProjectV2ItemById`, so the add costs 1 point and needs no second
lookup (asking for it costs nothing: it is one more field on the same query). Only the item whose project id matches counts. Exits `1` when the issue
does not exist.

## `scripts/link-item.sh`

`link-item.sh --parent <owner/repo#p> --child <owner/repo#c> [--project-id <project node
id>]` — links the child as a sub-issue of the parent by NOTES § *Creating an item* →
*Sub-issue linking*, the one procedure for a link made outside `create-item.sh`.
Arguments are checked before any GitHub call. The child is looked up first (one GraphQL
query for its node id and current `parent`): already under `--parent` → `via:
"existing"` and nothing runs; under a different parent → not linked, stderr `has parent
<owner/repo#n>`, exit `1` — re-parenting is never its job. Otherwise the ladder runs and
the first rung that succeeds wins, each failure one stderr line `<rung>: <reason>`:
`native` (only when `gh issue edit --help` lists `--add-sub-issue`), `graphql` (the
`addSubIssue` mutation, always available), `extension` (only when `gh extension list`
shows `sub-issue`; never installed), `tasklist` (a `- [ ] #<c>` line, `- [ ] <owner>/<repo>#<c>`
across repos, appended to the parent body unless the body already references the child).

With `--project-id` it then puts the child on that board, whether or not the link
succeeded: an item `item-id.sh` finds is reused, else the 1-point `addProjectV2ItemById`;
a failure is one stderr line `board-add: <reason>`. Prints one JSON line on every exit but
`2`:

```json
{"linked": true, "via": "graphql", "boardItem": "PVTI_…"}
```

`via` is `existing`, `native`, `graphql`, `extension`, `tasklist`, or `null` when not
linked; `boardItem` is `null` without `--project-id` or when the add failed. Exits `0`
linked (and on the board with `--project-id`), `1` not linked (a lookup failed, the child
has another parent, or every rung failed), `2` bad arguments (nothing printed, no `gh`
call), `3` linked but the board add failed. Fixtures: `kp-gh-lib/tests/link-item/run.sh`.

## `scripts/set-status.sh`

`set-status.sh <project-id> <item-id> <field-id> <option-id>` — moves one item's
single-select field, in practice the board's **Status**, with the
`updateProjectV2ItemFieldValue` mutation. Every id is one the preamble or `item-id.sh`
already returned. Prints the move:

```json
{"itemId": "PVTI_…", "fieldId": "PVTSSF_…", "optionId": "47fc9ee4"}
```

`gh project item-edit` is the obvious command and the one that has silently failed to
move Status across runs, which is why every Status write in the family goes through this
script instead — one 1-point mutation, bounded by `GH_TIMEOUT_SECONDS` (default 30). A
`200` carrying `errors` counts as a failure, not a move. Exits `1` on a failed mutation,
with the GraphQL errors on stderr, and `2` on bad arguments. Writes to other
single-select fields (`Priority`) still use `gh project item-edit`, which works there.

## `scripts/unblock-dependents.sh`

`unblock-dependents.sh <owner/repo> <issue-or-pr> <project-id> <status-field-id>
<blocked-option-id> <ready-option-id>` — once a work item has merged, moves each dependent
that nothing else blocks from `Blocked` to `Ready`. `<issue-or-pr>` is that item: the
issue the merged PR closed, or the merged PR itself when it closes no issue. The ids are
the ones the caller already resolved with `resolve-board.sh`:

```json
{"promoted": ["example-org/shop-tools#41"],
 "skipped": [{"issue": "example-org/shop-tools#42", "reason": "blocked on example-org/shop-tools#40"}]}
```

A dependent is an issue carrying, outside the human-only fence, the line
`blocked-by: #<n>` (in `<owner/repo>`) or `blocked-by: <owner/repo>#<n>` (in any repo of
the same owner), `<n>` being that issue or PR number. Two REST issue searches find
candidates; search is over-broad, so each hit counts only once its exact marker line is
read — `#380` never counts for `#38`. A dependent is promoted only when it is open,
labelled `type:coding`, `Blocked` on this board, every `blocked-by:` blocker it lists is
done, and the `kp-do-gh-task-loop` §1.3 open-decision check finds nothing. A blocker is
done when it is an issue that is closed or a pull request that is merged: REST reports a
PR closed unmerged as `closed` too, so the script reads the PR's
`pull_request.merged_at`, and an open or unmerged PR keeps the dependent where it is.
Every other dependent stays where it is and is listed
under `skipped` with one of: `closed`, `not type:coding`, `not on this board`,
`status is not Blocked (<status>)`, `blocked on <owner/repo>#m`, `blocked on decision #d`.
A promoted dependent is no longer `Blocked`, so a re-run moves nothing twice.

Board access is one `item-id.sh` call per open `type:coding` dependent plus one
`set-status.sh` per promotion; every other read is REST. Issue text never reaches a
shell. Exits `1` at the first failed lookup or write — including a secondary-limit `403`,
never retried — and prints no JSON; the calling skill notes it and carries on.

## `scripts/find-marker.sh`

`find-marker.sh <owner/repo> <marker> (<value> | --any-value) [--state open|closed|all]
[--label <name>]… [--scope repo|owner] [--comments] [--from-file <json>]` — the issues
that carry the marker line `<marker>: <value>`. Every dedup and referrer lookup on a
marker calls it rather than describing the search, and keeps its own rule about what to
do with the hits:

```json
[{"number": 41, "repo": "example-org/shop-tools", "state": "OPEN", "labels": ["type:coding"],
  "url": "https://github.com/example-org/shop-tools/issues/41", "value": "#38",
  "where": "body", "commentId": null}]
```

One REST `search/issues` query per written form of the value (an issue reference has
two), paginated to GitHub's 1,000-result cap, for the quoted phrase
`"<marker>: <value>"` — unquoted, GitHub reads `<marker>:` as an unknown qualifier and
returns nothing. `--scope repo` (default) searches `repo:<owner/repo>`, `--scope owner`
searches `user:<owner>`, which covers an organization's repos too; `--state` defaults to
`open`, and each `--label` is a further AND filter. `--any-value` searches `"<marker>:"`
and returns whatever value each confirmed line carries.

Search is over-broad, so a hit counts only when a line of its body, trimmed, is exactly
`<marker>: <value>` — bare, or as a whole `<!-- <marker>: <value> -->` line, the form
skill-output markers take — case-sensitive — outside every human-only fence and every
`<details>` … `</details>` block (nesting counted; an unclosed start fences to the end).
An issue-reference value matches both forms: `#38` matches `#38` and `<owner/repo>#38`
only in hits from `<owner/repo>` (under `--scope owner`, pass the full form);
`<owner/repo>#38` matches itself and `#38` in a hit from that repo. `#380` never matches
`#38`, and a line carrying several values (`blocked-by: #38 #39`) never matches `#38`. `--comments` also searches
`in:comments` and confirms against each comment, giving `where: "comment"` and the
comment's id. There is one entry per confirmed line, so an issue can appear more than
once — under `--any-value`, once per distinct value. `state` is upper-case, as `gh issue
list` prints it.

`--from-file` takes `{"issues": [{"number", "repo", "state", "labels", "body",
"comments": [{"id", "body"}], "url"}]}` in place of the search and reads, with the
scope, state and label filters applied to it; the fixtures in `tests/find-marker/` use
it. Issue text never reaches a shell. Exits `0` with a possibly empty array, `1` on a
failed GitHub call (no JSON), `2` on bad arguments.

## `scripts/ensure-labels.sh`

`ensure-labels.sh --repo <owner/repo> <label>[=<hex>]…` — makes sure every label an item
creator is about to apply exists in the repo, in the family's color. Every creator calls
it before filing rather than hand-running `gh label create`:

```
exists type:coding
created repo:demo
updated model:opus
```

One line per argument, in order. The repo's labels are read once over REST
(`repos/<owner/repo>/labels`, paginated); an absent label is created and a present one
whose color differs (compared case-insensitively) is recolored, both with `gh label create
<label> -R <owner/repo> --color <hex> --force`; a matching one makes no call. Names match
case-insensitively, as on GitHub. The color is the `=<hex>` suffix (six hex digits, no
`#`) when given, else the built-in map, which is the family's color list:

| label | color | label | color |
|---|---|---|---|
| `type:coding` | `1d76db` | `type:audit` | `0052CC` |
| `type:epic` | `5319e7` | `needs-contract` | `D93F0B` |
| `type:decision` | `d93f0b` | `model:opus` | `B60205` |
| `type:question` | `fbca04` | `model:sonnet` | `FBCA04` |
| `type:research` | `0e8a16` | `model:haiku` | `0E8A16` |
| `type:conflict` | `b60205` | any `repo:*` | `6E7781` |

A model tier label `model:<family>-<effort>` — `<family>` one of `opus`, `sonnet`,
`haiku` and `<effort>` one of `low`, `medium`, `high`, `xhigh`, `max`, both matched
case-insensitively — takes the color of `model:<family>` (`model:opus-xhigh` →
`B60205`). Any other unknown `model:*` label (e.g. `model:gpt-high`) still needs a
`=<hex>` suffix.

No GraphQL and no Projects call. Exits `0` when every label is ensured, `1` on a failed
`gh` call (stderr names the label; the lines before it are already printed), `2` on bad
arguments — a missing `--repo` or label, a malformed hex, or a label with neither a
suffix nor a map entry — before any call. Fixtures: `tests/ensure-labels/`.

## `scripts/repo-code.sh`

`repo-code.sh <owner/repo> [--config <path>]` — the `[<REPO-CODE>] ` title prefix and the
`repo:<name>` label for an item filed in `<owner/repo>`, resolved in the order of
`NOTES.md` § *Repo identification*:

```json
{"code": "SKILL", "label": "repo:kp-skills"}
```

First hit wins: `repoCodes["<owner/repo>"]` in `--config` (default
`.claude/spec-sync.json` under the current directory; a missing file skips the step) →
the code already in use, from one REST read of the repo's `repo:<name>`-labelled issues
(`state=all`, 100 per page, pull requests dropped), taken from titles matching
`^\[([A-Z0-9][A-Z0-9-]*)\] ` — the most frequent code, a tie going to the code whose own
highest issue number is largest → derived from the repo name, its first hyphen-separated
segment dropped when it has three or more, upper-cased (`shop-data-api` → `DATA-API`,
`kp-skills` → `KP-SKILLS`). Never a GraphQL or Projects call. Exits `0` printed, `1` on a
failed `gh` call, `2` on bad arguments or an unparseable config. Fixtures:
`tests/repo-code/`.

## `scripts/comment-once.sh`

`comment-once.sh <owner/repo> <n> --marker <m> --body-file <f> [--add-label <name>
--label-color <hex>]` — posts the body file as a comment on issue or PR `<n>` only when
no existing comment on it already carries `<m>`. Every "post it once" guard keyed on a
single marker calls it rather than reading the comments itself, so a re-run stacks
nothing.

Arguments are checked before any GitHub call (exit `2`): `<n>` a positive integer,
`--marker` non-empty, the body file readable and containing `<m>` — otherwise a later run
could never find the comment — and `--add-label` and `--label-color` given together.

With `--add-label`, `gh label create <name> --color <hex> --force` and `gh issue edit <n>
--add-label <name>` run first, on every call, whether the comment is then posted or
already there — both are idempotent. It then reads every comment on `<n>` (`gh api
--paginate repos/<owner/repo>/issues/<n>/comments`, all pages; the endpoint also returns
a PR's conversation comments). A comment matches when its body contains `<m>` as a plain,
case-sensitive substring. It prints one line:

```
exists <id>    a comment already carries the marker; <id> is the oldest such; nothing posted
posted <id>    the body file was posted as the new comment <id>
```

Comment text never reaches a shell. Exits `0` on `posted` or `exists`, `1` when a `gh`
call fails (nothing on stdout, the call's stderr passed through), `2` on bad arguments.
The fixtures in `tests/comment-once/` drive it against a fake `gh`.

## `scripts/body-parts.py`

The fence and marker parts of an issue body that a rewrite must copy rather than retype,
and the human-only fence strip. Three subcommands:

- `split <owner/repo> <n> <prefix> [--from-file <body-file>]` reads the body with `gh
  issue view … --json body -q .body` (or the file's bytes) and writes `<prefix>-orig.md`
  (the body byte for byte), `<prefix>-fence.md` (the first fence plus one newline, empty
  when there is none) and `<prefix>-markers.md` (outside that fence, every
  `^[a-z][a-z0-9-]*: ` line except `serves:`, `spec:`, `code:`, `decision:` and
  `dismissed:`, in body order). A start marker with no end after it writes
  `<prefix>-orig.md` only and prints `unclosed-fence` on stderr.
- `assemble <prefix> <sections-file>` writes `<prefix>-draft.md` from the non-empty
  fence, sections and markers, one blank line between them, then re-cuts the draft and
  compares its fence and markers byte for byte with the split's; a difference (an
  unclosed fence in the draft is one) is a unified diff on stderr, and the draft stays on
  disk.
- `strip` copies stdin to stdout with every human-only fence removed (an unclosed one to
  the end of the body). Its output hashes to the `body-sha256:` `kp-review-gh-pr`
  verdicts record, so the regex must not change.

Exits `0` ok, `1` the `assemble` check failed, `2` bad arguments, `3` an unclosed fence
(`split`), `4` the `gh` read failed (`split`). Issue text never reaches a shell. The
fixtures in `tests/body-parts/` cover every subcommand, offline.

## `scripts/set-marker.sh`

`set-marker.sh <owner/repo> <n> <marker> (--add <value> | --replace <old> <new> |
--remove <value>) [--from-file <json>]` — adds, replaces or removes one marker line
`<marker>: <value>` on issue `<n>`, idempotently. Every marker-line hand edit on an
existing issue — re-pointing a `blocked-by:` edge, clearing a waiter, adding a
`spec-pr:` — calls it rather than describing the edit; a body built whole at creation
does not.

```json
{"changed": true}
```

```json
{"changed": false, "body": "spec-ref: REQ-7\nblocked-by: #38\n"}
```

It reads the body with `gh issue view <n> --json body --jq .body` and, only when the
edit changed it, writes it back with one `gh issue edit <n> --body-file <tmp>`; a no-op
makes no write call. Line endings and every byte it does not edit are preserved.

Only an eligible line is read, changed or removed: one lying wholly outside every
human-only fence and every `<details>` … `</details>` block, by `find-marker.sh`'s rules
(nesting counted; an unclosed start fences to the end). A line matches `<marker>:
<value>` as in `find-marker.sh` — trimmed, exact, case-sensitive, bare or as a whole
`<!-- <marker>: <value> -->` line — with an issue reference judged from `<owner/repo>`:
`#38` and `<owner/repo>#38` match each other, `#380` never matches `#38`, and a line
carrying several values (`blocked-by: #38 #39`) never matches.

- `--add <value>` — nothing when a matching line exists; otherwise the line goes directly
  after the last eligible `<marker>:` line, or at the end of the body, after one blank
  line unless the last non-empty line is already a `<word>: <text>` marker line. The
  value is written exactly as given.
- `--replace <old> <new>` — each matching `<old>` line becomes `<marker>: <new>`, keeping
  its indentation and bare-or-comment form; when a line already matches `<new>`, the
  `<old>` lines are deleted instead. No `<old>` line, or `<old>` and `<new>` naming the
  same value, is no change — it never adds.
- `--remove <value>` — every matching line is deleted.

`--from-file` takes `{"body": "<text>"}` in place of the read, makes no GitHub call, and
adds the resulting `body` to the output; the fixtures in `tests/set-marker/` use it.
Issue text never reaches a shell. Exits `0` (including no change), `1` on a failed `gh`
call (no JSON), `2` on bad arguments.

## `scripts/epic-convert.sh`

`epic-convert.sh <owner/repo> <n>` — turns a decomposed coding item into its epic
(`kp-decompose-gh-task` §7), so the conversion is applied the same way on every run:

```json
{"changed": true, "title": "[KP-SKILLS] Sub-Epic: Foo", "labels": ["repo:kp-skills", "type:epic"]}
```

Reads the issue once over REST (`gh api repos/<owner/repo>/issues/<n>`; no GraphQL, no
Projects call). A pull request, or an issue carrying neither `type:coding` nor
`type:epic`, is refused. The target labels are the current ones minus `type:coding` and
every `model:*` (an epic carries none — NOTES.md § *Model-tier rubric*), plus `type:epic`;
the target title is unchanged when it already contains `Sub-Epic: `, else `[<CODE>] <rest>`
becomes `[<CODE>] Sub-Epic: <rest>`, else `Sub-Epic: <title>`. Each field converges on its
own, so a resumed or half-converted parent gets only what it still lacks and the prefix
never stacks. Nothing to change → no further call and `"changed": false`. Otherwise
`ensure-labels.sh --repo <owner/repo> type:epic` runs first when `type:epic` is not yet on
the issue, then exactly one `gh issue edit` carries every `--remove-label`, the
`--add-label` and the `--title`. `labels` is the final set, sorted. `ensure-labels.sh` is
found through `KP_GH_LIB_BIN`, default the script's own directory; the fixtures in
`tests/epic-convert/` fake it and `gh`. Issue text never reaches a shell.

Exits `0` converted or already converted, `1` on a failed `gh` or `ensure-labels.sh` call
(stderr names it, no JSON), `2` on bad arguments before any call, `3` when the issue is not
a coding item or epic (stderr names its `type:*` labels, or `pull request`; nothing
written).

## `scripts/milestone-of.sh`

`milestone-of.sh <owner/repo> <issue-or-pr>` — the milestone the issue sits in: its
nearest ancestor on the sub-issue parent chain that is a milestone epic (`type:epic`
carrying `spec-ref: milestone:M<n>` outside the human-only fence):

```json
{"issue": "example-org/shop-api#77", "state": "OPEN",
 "milestone": "M5", "rank": 5, "epic": "example-org/shop-api#6",
 "root": "example-org/shop-spec#3"}
```

`state` is the item's own: `OPEN` | `CLOSED` | `MERGED`, where `MERGED` occurs only for a
pull request and a pull request's `CLOSED` means closed unmerged. `milestone`, `rank` and
`epic` are `null` when no ancestor is a milestone epic — the issue is outside the
milestone rules. A pull request is accepted too; it has no parent, so all three are
always `null` for it. `rank` is the id's number, so callers compare milestones
numerically (M9 before M10). A marker whose id is not `M<number>` is warned about on
stderr and not treated as a milestone epic. `root` is the topmost ancestor on the sub-issue
parent chain — the item's chain root — or the item itself when it has no parent, so a pull
request's `root` is always itself. One 1-point query covers all eight levels of
nesting GitHub allows. Exits `1` when no issue or pull request has that number.

## `scripts/milestone-gate.sh`

`milestone-gate.sh --project <owner/number> <owner/repo> <issue>` — whether the
whole-milestone gate lets the issue launch, counting only milestones in the repositories
linked to that project:

```json
{"issue": "example-org/shop-api#77", "milestone": "M5", "epic": "example-org/shop-api#6",
 "waitingOn": "M2", "openEarlier": ["example-org/shop-api#17", "example-org/shop-api#19"],
 "crossEdges": [{"issue": "example-org/shop-api#17", "milestone": "M2",
                 "blockedBy": "example-org/shop-api#40", "blockerMilestone": "M4"}]}
```

`waitingOn` is `null` when the gate is open: the issue has no milestone, or every non-epic
item of every earlier milestone is closed. Otherwise it is the earliest milestone with an
open non-epic item, and `openEarlier` lists that milestone's open non-epic items.
`crossEdges` lists each `blocked-by:` edge, from the issue or an `openEarlier` item, onto
an open issue in a later milestone than the dependent's own — an edge that stalls both
milestones. A pull-request blocker has no milestone, so it is never a cross edge.

Milestone epics are found with one REST issue search over the owner of the issue's
milestone epic, filtered to the project's linked repos (one 1-point GraphQL lookup), each
hit confirmed by its label and marker line. The walk then goes down
the earlier milestones' sub-issue trees in ascending order — 1 point per page of children,
into every sub-epic, closed ones included, but never into a nested milestone epic — and
stops after the first milestone with open work. Each `blocked-by:` target costs one
`milestone-of.sh` call. Exits `1` at the first failed lookup, or when the project is not
found or links no repository, and prints no JSON; `2` on bad arguments, `--project`
included.

`milestone-gate.sh --project <owner/number> --current` — the project's current milestone:

```json
{"project": "example-org/4", "milestone": "M2",
 "epics": ["example-org/shop-api#6", "example-org/shop-spec#12"]}
```

`milestone` is the earliest milestone that is not done — by the very test the gate form
applies, so the two never disagree — or the latest milestone when every one is done. It
is `null`, with `epics` `[]`, when the project's linked repos hold no milestone epic: the
project does not use milestones. `epics` lists every milestone epic carrying that id,
sorted by `owner/repo` then number; a caller picks the one in its filing repo, else the
first. The epic search runs over the project owner. Cost: the same 1-point linked-repos
lookup, at most 3 searches, and 1 point per page of children of each milestone walked,
stopping at the first one not done. Mixing `--current` with an issue is a usage error
(exit `2`).

`milestone-gate.sh --project <owner/number> --milestone M<k>` — whether one named
milestone is done, and the repos it spans:

```json
{"milestone": "M1", "done": true,
 "repos": ["example-org/shop-api", "example-org/shop-spec"]}
```

`done` is the same test the other two forms apply. `repos`, sorted, is every linked repo
holding a milestone epic carrying M<k>, an item under those epics, a `type:audit` carrying
`audit-unit: milestone:M<k>`, or an `audit-close: M<k>` decision — the repos
`milestone-tag.sh` tags. An M<k> no epic carries prints `"done": false, "repos": []`.
Cost: the linked-repos lookup, at most 3 searches, and 1 point per page of the
milestone's children. The flag, not the argument count, tells this form from the gate
form; a malformed id is a usage error (exit `2`).

## `scripts/milestone-tag.sh`

`milestone-tag.sh --project <owner/number> M<k>` — tags a done milestone: a lightweight
`refs/tags/milestone/M<k>` on each repo's default-branch HEAD, for every repo in
`milestone-gate.sh --milestone`'s `repos` (found through `KP_GH_LIB_BIN`, default its own
directory). It prints one line per outcome:

```
not-done M<k>
tagged <owner/repo> milestone/M<k> <sha>
exists <owner/repo> milestone/M<k> <sha>
failed <owner/repo>: <first stderr line>
```

`not-done` creates nothing. An existing tag is never moved (`exists`, with the SHA it
points at), so a re-run tags only the repos an earlier run missed. A failed lookup or
create for one repo prints `failed` and the script carries on. Cost per repo: three REST
calls (repo, branch HEAD, tag lookup) and a POST when the tag is missing. Exits `0` when
every repo is tagged or exists (or `not-done`), `1` when the gate lookup or any repo
failed, `2` on bad arguments. Its callers, `kp-audit-alignment` §8 and
`audit-close-move.sh` (for `kp-resolve-spec-decision` § *Audit-close branch* option B),
report its lines and never fail on it. Both call it only after `milestone-merge.sh`
exits `0`.

## `scripts/milestone-merge.sh`

`milestone-merge.sh --project <owner/number> M<k>` — merges a done milestone's
integration branch `release/M<k>` into the default branch of every repo in
`milestone-gate.sh --milestone`'s `repos` (found through `KP_GH_LIB_BIN`, default its own
directory), so the tag `milestone-tag.sh` places next lands on the merge commit
(`NOTES.md` § *Audit gate* → *Milestone branch*). Per repo carrying `release/M<k>`: the
default branch is merged into it (`POST repos/{r}/merges`), the open `release/M<k>` →
default PR is found or created (body carries `milestone-merge: M<k>` and no closing
keyword), its CI is waited on (`gh pr checks --watch`, 540 s), and it is merged with `gh pr merge --merge --delete-branch` — a merge commit,
because the per-task squash commits are what `trace-matrix.sh` maps to items;
`guard_merge.py`'s `--squash` rule guards only sessions rooted in kp-skills. It prints
one line per outcome:

```
not-done M<k>
no-branch <owner/repo>
conflict <owner/repo>: <first error line>
ci-failed <owner/repo> <pr>
ci-pending <owner/repo> <pr>
failed <owner/repo>: <first stderr line>
merged <owner/repo> <pr> <sha>
```

`not-done` touches nothing; `no-branch` is every spec repo and any repo with no milestone
branch; `<sha>` is the new default-branch HEAD. A repo that fails goes no further and the
script carries on with the next. A merged repo's branch is deleted, so a re-run reports it
`no-branch` and retries only the repos still carrying `release/M<k>`. Unlike
`spec-pr-fastmerge.sh`, `no checks reported` is not a pass at once
(decision #343: a whole-milestone merge never lands without CI having run): it
re-polls `gh pr checks` (60 s timeout) after `sleep 30`, up to 10 times; once checks
appear the watch runs again and decides, and only a PR still reporting none after the
10th re-poll passes. Each repo with a branch can therefore wait up to
540 + 10 × (30 + 60) + 540 s, past the 10-minute `Bash` cap, so a caller runs it
detached with an exit sentinel and waits in the foreground per `NOTES.md` § *Waiting in a
headless session*. Exits `0` when every repo merged or has no
branch (or `not-done`), `1` when the gate lookup or any repo failed, `2` on bad
arguments. Its callers, `kp-audit-alignment` §8.4 and `audit-close-move.sh` (for
`kp-resolve-spec-decision` § *Audit-close branch* option B), report its lines, skip the
tag when it exits non-zero, and never fail on it. The fixtures in
`tests/milestone-merge/` cover it offline.

## `scripts/milestone-branch.sh`

`milestone-branch.sh <owner/repo> <issue> [--create]` — resolves the branch an item
builds on and merges into (`NOTES.md` § *Milestone branch*): `release/M<k>` when
`milestone-of.sh` (found through `KP_GH_LIB_BIN`, default its own directory) finds
milestone M<k>, else the default branch. It prints one JSON line:

```
{"milestone": "M3", "branch": "release/M3", "exists": true, "created": false, "default": "main"}
```

No milestone prints `milestone` and `branch` as `null` and creates nothing. With
`--create`, a missing `release/M<k>` is created at the default-branch HEAD (`created:
true`) — unless an earlier `release/M<j>` (j < k) still exists, which means that
milestone has not merged yet: then it creates nothing, prints `earlier-unmerged
release/M<j>` (the lowest such j) on stderr and exits `3`. Only names matching
`release/M<digits>` exactly count. Cost: 1 GraphQL point and 2–5 REST calls. Exits `0`
resolved, `1` when an API call or `milestone-of.sh` failed (stderr names it, nothing on
stdout), `2` on bad arguments, `3` earlier-unmerged. `kp-do-gh-task` §1.1 is its caller;
the fixtures in `tests/milestone-branch/` cover it offline.

## `scripts/audit-close-move.sh`

`audit-close-move.sh --repo <T> --issue <n> --milestone M<k> --spec-repo <S> --item
<owner/repo>#<m> [--item …] [--project <owner/number>]` — carries out option B of an
`audit-close: M<k>` decision (`kp-resolve-spec-decision` § *Audit-close branch*) end to
end. `<T>` is the repo the decision is filed in; each `--item` is one finding the decision
body lists — the caller reads them from the body, the script never parses it. Siblings are
found through `KP_GH_LIB_BIN`, default its own directory. Every argument is checked before
any call. Steps, in order, each checking before it acts so a re-run finishes a partial one:

1. **Next milestone epic** — `find-marker.sh <S> spec-ref --any-value --scope owner
   --label type:epic`; the lowest `milestone:M<j>` with `j > k` (numeric, so M10 after
   M2), ties by `repo` then `number`. None → prints `{"target": null}` and exits `0`,
   having written nothing.
2. **Re-parent** — per item, `milestone-of.sh`: open in M<k> → `addSubIssue` with
   `replaceParent:true` under that epic (`moved`); already in M<j> → `already`; else
   `skipped` with reason `closed` or `milestone <id|none>`. `blocked-by:` lines are not
   touched.
3. **Acceptance audit** — `gh label create type:audit --force`, then `file-audit.sh`
   titled `Audit M<k> <YYYY-MM-DD>`, deduped on `audit-unit: milestone:M<k>` and
   `audit-accepted: <T>#<n>`, its body naming the moved and already items; closed when
   still open. Never linked to an epic.
4. **Close the decision** — a `Resolved → no spec change: audit-close. Decision: B — moved
   <refs> to M<j>; audit #<a>` comment unless a comment already starts with `Resolved → `,
   then `gh issue close --reason completed` when still open.
5. **Merge, then tag**, only after step 4 (`milestone-gate.sh` counts M<k> not done
   while its decision is open): with `--project`, `milestone-merge.sh --project
   <owner/number> M<k>`, then `milestone-tag.sh` with the same arguments only when the
   merge exited `0` — otherwise `tag` is `"skipped"` and `tagExit` `null`. Each one's
   stdout lines and exit code are recorded and never fail this script.

```json
{"target": "M2", "epic": "example-org/shop-spec#40", "moved": ["example-org/shop-api#77"],
 "already": [], "skipped": [{"item": "example-org/shop-api#78", "reason": "closed"}],
 "audit": {"number": 91, "url": "https://github.com/…/issues/91", "reused": false},
 "decisionClosed": true, "merge": ["merged example-org/shop-api 120 <sha>",
 "no-branch example-org/shop-spec"], "mergeExit": 0,
 "tag": ["tagged example-org/shop-api milestone/M1 <sha>"], "tagExit": 0}
```

`merge`, `mergeExit`, `tag` and `tagExit` are all `null` without `--project`. Exits `0` when done (including
`{"target": null}`), `1` when a `gh`, `find-marker.sh`, `milestone-of.sh` or
`file-audit.sh` call failed — it stops at that step, prints no JSON, and stderr names the
step and the call's first stderr line — and `2` on bad arguments, nothing called. The
fixtures in `tests/audit-close-move/` cover it offline.

## `scripts/edge-check.sh`

`edge-check.sh --project <owner/number> <dependent> <blocker> [--dependent-epic
<owner/repo#e>] [--from-file <json>]` — decides one proposed `<dependent> blocked-by
<blocker>` edge before a skill writes its marker, per `NOTES.md` § *Milestone sequencing* →
*Acyclicity* and *Edges stay inside one milestone*. A `Y blocks: X` write is checked as
`X blocked-by Y`. `<dependent>` is `<owner/repo#n>`, or `draft:<M<k>|none>` for an item
not created yet (its milestone from `milestone-place.sh`, its epic in `--dependent-epic`);
`<blocker>` is an issue or pull request. Writes nothing.

```json
{"verdict": "pull-forward", "path": [], "dependentMilestone": "M9",
 "blockerMilestone": "M10", "pullForwardEpic": "example-org/shop-spec#90"}
```

- **`cycle`** — a self-edge, a blocker the dependent names in `resolves:`, or a
  breadth-first walk from the blocker over its prerequisites (its own `blocked-by:`
  targets, and every issue in the project's linked repos whose `blocks:` names it or its
  `spec-ref:`) that reaches the dependent. `path` runs blocker → dependent; the milestones
  are `null`. The caller drops the edge and reports it.
- **`ok`** — same milestone, or either end has none (a pull request never has one): write
  it.
- **`drop-earlier`** — the blocker's milestone runs first: drop it and report
  `dropped X blocked-by Y (M<j> runs before M<k>)`.
- **`pull-forward`** — the blocker's milestone runs later: pull it forward into
  `pullForwardEpic` (the dependent's epic; `null` for a draft given no `--dependent-epic`),
  then write the edge. The pull itself is the caller's.

Milestones come from `milestone-of.sh` (numeric, so M9 before M10). The `blocks:` lines
come from one `find-marker.sh` search per repo owner, and each walked node is one REST
read. Exits `0` for every verdict, `1` on a failed lookup (no JSON), `2` on bad arguments.
`--from-file` replaces every GitHub read with a fixture; the fixtures in
`tests/edge-check/` run offline with `kp-gh-lib/tests/edge-check/run.sh`.

## `scripts/create-item.sh`

`create-item.sh --repo <owner/repo> --title <t> --body-file <f> --label <l>…
[--project <owner/number>] [--priority top] [--status <name>] [--assignee <login> |
--assign-owner] [--origin <owner/repo#n>] [--parent <owner/repo#n>] [--no-place]
[--link-under <owner/repo#p>] [--cache <file>] [--decided-body-file <f>]` — the whole
chain of creating one item,
run after the caller's own dedup, climb and body: `gh issue create`, the `__ISSUE__`
substitution (`gh issue edit --body-file`), the assignee, the board add with the 1-point
`addProjectV2ItemById` (ids from `resolve-board.sh` and `item-id.sh`'s `contentId`),
`--priority top` (the board's first `Priority` option), `--status` through
`set-status.sh`, `milestone-place.sh` with `--origin` / `--parent` / `--cache`, and the
sub-issue link (`addSubIssue`) the placement asks for. A `type:decision`,
`type:question` or `type:conflict` label also pings the operator on Telegram right after
the create — `<repo>#<n> <type>: <title> — needs your call <url>` — through the send
script at `KP_MSG_ME_SEND` (default `~/.claude/skills/kp-msg-me/scripts/send.sh`;
`NOTES.md` § *Operator notifications*).

`--decided-body-file <f>` files a creator-decided `type:decision` (`NOTES.md` § *Human-gated
item body* → *Confidence and creator-decided items*): right after the body substitution
the file's `__ISSUE__` is substituted too and it is posted as the issue's first comment
(`gh issue comment --body-file`), `--status` defaults to `Ready` so `kp-do-gh-ready-items`
sweeps the item, and the ping is sent only when that comment failed or `Ready` did not
land (the `status` or `board-add` step skipped, or no `--project`) — then the item is an
ordinary operator-gated one. Any label other than `type:decision` with it exits `2`.

`--assign-owner` assigns the project owner only on a user-owned board; `--assignee`
wins over it. `--parent` is also the parent the item is linked under. `--link-under <p>`
links it under a parent the caller's own rule chose and skips placement; `--no-place`
(a milestone epic) skips placement. `--cache` defaults to
`${TMPDIR:-/tmp}/kp-milestone-current-<owner>-<number>.json`. Without `--project` the
board add, priority, status, placement and link are skipped with reason `no project`. It
creates no labels and adds no title prefix.

```json
{"number": 12, "url": "https://github.com/…/issues/12", "itemId": "PVTI_…",
 "milestone": "M2", "epic": "example-org/shop-api#6", "link": "item", "skipped": []}
```

Every step after the create is best-effort: one that fails or does not apply is recorded
as `{"step": "<substitute|decided|notify|assignee|board-add|priority|status|place|link>", "reason":
"…"}` in `skipped`, and the chain carries on. With `--no-place` / `--link-under` the
placement fields are `null`, `null`, `"none"`. Exits `0` when the issue was created, `1`
when the create failed (nothing else runs), `2` on bad arguments.

## `scripts/file-audit.sh`

`file-audit.sh --repo <owner/repo> --title <t> --body-file <f> [--tokens <start-iso>
<marker>] [--dedup-line '<marker>: <value>']…` — files a closed `type:audit` report issue
in one call, for `kp-audit-alignment` §8.3 and `audit-close-move.sh` (option B of
`kp-resolve-spec-decision` § *Audit-close branch*). A `type:audit` report is never placed, assigned or added to a
board, so it does not go through `create-item.sh`. In order: `ensure-labels.sh --repo
<repo> type:audit`; with `--dedup-line`, one `find-marker.sh <repo> <marker> <value>
--state all --label type:audit` per line, and an issue every line's search returned is a
hit — the highest-numbered hit is closed if still open and printed with `"reused": true`,
and nothing else runs; `gh issue create --label type:audit --body-file <f>`; with
`--tokens`, `report-tokens.sh <start-iso> <marker> <repo> <n>`, whose row replaces every
`__TOKENS__` in the body (`gh issue edit --body-file`) — best-effort, a failure prints
`file-audit: token fill skipped — <reason>` on stderr and the script carries on; then
`gh issue close`. Arguments are checked before any call: a `--dedup-line` not shaped
`<marker>: <value>`, or `--tokens` with no `__TOKENS__` in the body, exits `2`.

```json
{"number": 12, "url": "https://github.com/…/issues/12", "reused": false}
```

Exits `0` when the report was filed or reused, `1` when a GitHub or sibling call failed
(stderr says which; a failed close leaves the issue open), `2` on bad arguments.

## `scripts/goal-question.sh`

The goal-question mechanics of `NOTES.md` § *Goal questions* in three subcommands, each
taking `--repo <owner/repo>`:

- `escalate --issue <n> --goal-title <t> --goal-body-file <f> --goal-ref <key>
  --missing-fact <text> [--creator <skill>]` — `kp-resolve-spec-decision-auto` §4.0's
  rewrite in place. Posts the escalation comment (the original title and body verbatim in
  a backtick fence one longer than the body's longest backtick run, `goal-ref: <key>`,
  `restore-type: type:decision`), then sets the goal title and body, then swaps
  `type:decision` for `type:question`. A latest escalation comment newer than any restore
  that already carries this key is not posted again (`already-escalated`). A fresh
  escalation pings the operator on Telegram like `create-item.sh` does for a new
  question; `already-escalated` and `restore` send nothing.
- `create --technical-body-file <f> --technical-title <t> --technical-type <label>
  --goal-body-file <f> --goal-title <t> --goal-ref <key> --missing-fact <text> --creator
  <skill> [--label <l>…] [--project …] [--priority top] [--assign-owner] [--origin …]
  [--parent …]` — `NOTES.md` § *Before raising a human-gated item* → *Creating the goal
  question*. Creates a `type:question` item through `create-item.sh` (the five optional
  flags passed through; without `create-item.sh` it falls back to `gh issue create` and
  the `__ISSUE__` substitution, skipping `create-item`), then posts the escalation comment
  holding the technical title and body with `restore-type: <technical type>`. When that
  comment fails it puts the technical title, body and label back and exits `3`.
- `restore --issue <n> --pr-url <url>` — `kp-resolve-spec-decision` § *Goal-answered
  branch*. Puts back the title and body from the latest escalation comment with
  `goal-answered: <key> via <url>` after the last marker line (else after the human-only
  fence, else at the top), swaps `type:question` for its `restore-type:` (default
  `type:decision`), and posts the `<!-- kp-resolve-spec-decision:restored -->` comment
  unless one newer than the escalation is already there.

Every step checks before it acts, so a re-run finishes a partial call.

```json
{"issue": 12, "action": "escalated", "commentId": 123, "title": "…",
 "labels": ["type:question"], "skipped": []}
```

`action` is `escalated`, `already-escalated`, `created`, `restored`, or `null` on exit
`3`. Exits `0` done, `1` a GitHub failure (after a change, `skipped` names the step —
`comment`, `edit`, `label`, `revert`, `notify`, or `create-item.sh`'s own), `2` bad arguments, `3`
the escalation comment could not be posted (nothing changed, or the created item was
reverted to the technical one).

## `scripts/milestone-place.sh`

`milestone-place.sh --project <owner/number> --repo <owner/repo> --cache <file>
[--origin <owner/repo#n>] [--parent <owner/repo#n>]` — where a newly created item goes
in the milestone-epic tree. `--repo` is the repo it is filed in, `--origin` the existing
item whose work produced it, `--parent` the parent the creating skill links it to (never
a milestone epic, which `milestone-of.sh` would read as having no milestone), and
`--cache` the run's `milestone-gate.sh --current` result: read when the file exists, else
looked up and written there on success, so a run pays for `--current` once. It makes no
GitHub call of its own — only `milestone-gate.sh --current` and `milestone-of.sh` on the
parent and origin.

```json
{"milestone": "M2", "epic": "example-org/shop-api#6", "link": "item"}
```

`milestone` and `epic` are `null`, with `link` `"none"`, when the project uses no
milestones. A parent already under a milestone epic gives its milestone and epic with
`link` `"none"`. Otherwise the target is the origin's milestone when that is not earlier
than the current one, else the current milestone and its epic in `--repo` (else the
first); `link` is `"item"` (link the new item under `epic`) without `--parent`, or the
parent's chain root `"owner/repo#r"` (link that root under `epic`). Exits `1` when a
lookup fails (its stderr passed through) or the `--cache` file is empty or not
`--current` output, which is left as it is; `2` on bad arguments, checked before the
cache is touched. The rule creating skills apply around it lives in `NOTES.md`
§ *Milestone sequencing* → *Every new item has a milestone*.

## `scripts/spec-index.py`

`spec-index.py <owner/repo>@<sha> [<path> …]` — one JSON object listing each spec file's
heading and `REQ-…` sections with line extent, bytes, `serves` goals and resolved `refs`
(every tracked `*.md` when no path is given); REST only, 30 s per `gh` call, cached in
`state/spec-index/` per SHA; exits `1` on a fetch or parse failure, `2` on bad arguments.

## `scripts/trace-matrix.sh`

`trace-matrix.sh <spec-repo> [--repo <target-repo>] [--milestone M<n> | --area <AREA> |
--all] [--ref <branch>]`, run from a checkout of the spec repo — one JSON object tracing
the spec's REQs to the merged items and PRs that cover them in the target repo and every
`requirementRepos` repo: `covered`, `uncovered`, `noServes`, `noSpecRef`, `untraced`
paths, each area's owning repo, `shas` and `refs` (the header documents the shape). Each
routed code repo is read at the milestone branch when the unit has one and it exists,
else the default branch: `--ref <branch>` (a `--milestone M<n>` run defaults it to
`release/M<n>`; an explicit `--ref` wins) is read when `repos/<repo>/branches/<branch>`
answers, else the default branch on a 404; `refs` names the branch read per repo and
`shas` its SHA. The spec repo is always read at its default branch. A merged PR whose
head branch starts with `release/` (a milestone merge PR) is skipped before its files are
fetched, in every scope.
`kp-audit-alignment` §1. REST and search only; exits `1` on a failed lookup, `2` on bad
arguments, when no target repo is named, or when a routed repo is not a plain
`owner/repo`. A PR's closing ref to a missing or inaccessible issue closes nothing rather
than failing the trace. Each merged PR's changed filenames are cached in
`kp-gh-lib/state/trace-cache/<owner>/<repo>.json` (lowercased, one file per routed repo),
shaped `{"version": 1, "prs": {"<PR number>": ["<filename>", …]}}`, so a later run skips
that PR's `pulls/<n>/files` call. An entry never changes, because a merged PR's files
never do; deleting the file is the only invalidation, and a missing or malformed one is
read as empty and rewritten.

## `scripts/audit-prev.sh`

`audit-prev.sh <spec-repo> <unit> <run-dir>` — finds an audit unit's previous round with
one `gh issue list -R <spec-repo> --label type:audit --state closed --limit 200 --json
number,body,closedAt`: of the issues whose body has a line exactly `audit-unit: <unit>`
(whole line, case-sensitive), the one with the greatest `closedAt`. It writes
`<run-dir>/prev.json` — `{"number", "closedAt", "lines"}`, `lines` being that body's
`audit-shas:`, `audit-filed:`, `unfiled:`, `refuted:` and `|` lines in body order — and
`<run-dir>/prev-refuted.md`, its `audit-shas:` line(s) then its `refuted:` lines, and
prints `{"number": <n>, "prevSpecSha": "<sha>" | null}`: the SHA after `<spec-repo>@` in
the `audit-shas:` entry whose repo equals `<spec-repo>` case-insensitively, `null` when
there is none. No match is the unit's **first round**: `prev.json` is `{}`,
`prev-refuted.md` empty, stdout `{}`. Exits `0` on a match or a first round, `1` when the
`gh` call fails (its stderr passed through, nothing on stdout, neither file written — each
goes through a temp file in `<run-dir>`), `2` on bad arguments, checked before any GitHub
call (not three positionals, a `<spec-repo>` not `<owner>/<name>`, an empty `<unit>`, a
`<run-dir>` that is not an existing directory). Caller: `kp-audit-alignment` §0.6;
`tests/audit-prev/run.sh` is its offline fixture.

## `scripts/fresh-checkout.sh`

`fresh-checkout.sh <path> [--ref <branch>]` — prints one directory holding the current
code of the clone at `<path>`: the milestone branch when the unit has one and it exists,
else the default branch. With `--ref` (callers pass `release/M<k>`), after the fetch,
an existing `origin/<branch>` is exported as below — the clone is never pulled or checked
out — and a missing one prints the one stderr line `fresh-checkout.sh: origin/<branch> not
found; reading origin/<default>` and falls through to the default-branch behaviour; a
`--ref` naming the default branch is the same as none. Without `--ref`, it reads
`origin/<default branch>`. It fetches origin (bounded), then
fast-forwards the clone with `git pull --ff-only` and prints `<path>` when the clone is on
its default branch with a clean work tree; otherwise (local edits, another branch, a
diverged branch or unpushed commits) it leaves the clone untouched, exports
`origin/<default branch>` (or the `--ref` branch) as a detached worktree at
`${TMPDIR:-/tmp}/kp-fresh-<repo-name>-<short-sha>` (reused at that SHA), prints that, and
names on stderr why the clone was not pulled. On every successful call, pulled or
exported, it evicts stale exports: after the fetch `git worktree prune` silently drops a
registered export whose directory is gone (so a vanished one at the current SHA is
re-added), and just before printing, each of this clone's own `kp-fresh-<repo-name>-*`
worktrees whose HEAD is the tip of no `refs/remotes/origin/*` branch is `git worktree
remove`d without `--force` — the current default-branch export and one at a live
`release/M<k>` tip survive. One with local changes is kept and named in one stderr line,
`fresh-checkout.sh: kept <path>: <git's message>`, on every call while it stays dirty.
Eviction never changes the exit code or the printed path, and touches only the clone's
registered worktrees, never a directory globbed from `$TMPDIR`. Accepted race: a
concurrent skill reading a now-stale export of this clone, including one another clone of
the same repo name reused at the same SHA, loses it mid-read and fails that read; its next call recreates the current one. Exits `0` when a directory was printed, `1` on a fetch or git
failure, `2` on bad arguments (a `--ref` that fails `git check-ref-format --branch` or
has a character outside `[A-Za-z0-9._/-]` included). `tests/fresh-checkout/run.sh` is its
offline fixture.

**The rule:** a skill that passes `--code-root` to `read-context.sh` or `lint-item.py`
passes the directory `fresh-checkout.sh` printed, never a raw clone path, so a stale or
edited clone never makes the lint or the cold reader judge old code. `kp-review-gh-pr`,
`kp-fix-pr` and `kp-do-gh-task` are exempt: they read a worktree at the PR head or
branched from `origin/<default branch>`.

## `scripts/ensure-checkout.sh`

`ensure-checkout.sh (<owner/name> --workspace <dir> [--clone] | --here) [--no-fetch]` —
resolves a repo's primary checkout, guards it, fetches it and prints its absolute
physical path.

- **`<owner/name> --workspace <dir>`** — the checkout is `<dir>/<name>`. A missing one is
  `gh repo clone`d there with `--clone` (bounded, 600 s), else refused. Its raw
  `remote.origin.url` (never `git remote get-url`, which applies `insteadOf`), with
  `git@host:` read as `host/` and a trailing `/` and `.git` stripped, must end in
  `/<owner>/<name>`, compared case-insensitively.
- **`--here`** — the checkout is the top level of the current directory's work tree; no
  origin check, since the caller does not know its repo yet (`preamble.sh` checks it).

Both modes require the checkout to be its own work tree's top level (a plain directory
inside another repo is not one) and a primary checkout — its `--git-common-dir` is its
own `.git` directory, never a linked worktree's. Unless `--no-fetch`,
`git fetch origin --prune` runs (bounded, 60 s). When the checkout is not clean — local
changes, or HEAD off the default branch (`origin/HEAD`; that half is skipped when it is
unset) — one stderr line precedes the path, `ensure-checkout.sh: <path>: not clean
(<reason>) — fresh reads are exported, not pulled`, with `<reason>` `local changes`,
`on <branch>, not <default>` or `on a detached HEAD, not <default>` (two joined by `; `).
The exit code and path are unchanged. `kp-do-gh-ready-items` §1.7–§1.8 notify on it once
per repo per pass; every other caller ignores it.

Exits `0` with the path printed, `1` on a clone or fetch failure, `2` on bad arguments,
`5` when there is no usable primary checkout (missing without `--clone`, not a git
checkout, a worktree, an origin naming another repo) — `preamble.sh`'s guard code. The
offline fixture is `tests/ensure-checkout/run.sh`. Called by `kp-do-gh-task-loop` and
`kp-do-gh-pr-loop` §0.2 (`--here --no-fetch`), `kp-do-gh-pr-loop-all` §0.2
(`<R> --workspace <ws> --clone`) and `kp-do-gh-ready-items` §0.2 (`--here --no-fetch`)
and §1.7–§1.8 (`<owner/name> --workspace <ws> --clone`).

## `scripts/worktree.sh`

`worktree.sh task <n> <slug> [--base <branch>]`, `worktree.sh fix <pr> <headRefName>`,
`worktree.sh review <pr> <headRefName> [--reclaim-only]` — run from inside the primary
checkout; names, reuses or reclaims the sibling worktree a run works in. `..` is the
parent of the checkout's top level, `<repo-name>` its `origin` repo name without owner.

- **`task`** — `../<repo-name>-task-<n>`. Reuses it when this checkout's `git worktree
  list` has it, else reuses the legacy `../task-<n>`, else adds it on a new branch
  `task/<n>-<slug>` from the base (`--base`, else `git symbolic-ref --short
  refs/remotes/origin/HEAD`, else the current branch), or on that branch when it already
  exists. No fetch, no fast-forward. For a milestone item `kp-do-gh-task` §3.1 fetches
  `release/M<k>` and passes `--base origin/release/M<k>` (`milestone-branch.sh`).
- **`fix`** — `../<repo-name>-fix-pr-<pr>`, legacy `../fix-pr-<pr>`, same reuse order. A
  new one is a real checkout of `<headRefName>`, never `--detach`. A reused one is
  fetched and fast-forwarded (`merge --ff-only origin/<headRefName>`) only when
  `rev-list --count origin/<headRefName>..HEAD` is `0`; otherwise it holds unpushed
  commits and is left as is (`ffSkipped: true`). Never `pull --ff-only`.
- **`review`** — `../<repo-name>-review-pr-<pr>`. Always removes it and the legacy
  `../review-pr-<pr>` first (each only when this checkout lists it, so another repo's
  same-named sibling is left alone), then, unless `--reclaim-only`, adds it detached at
  `origin/<headRefName>`. Never reuses.

No mode creates a legacy name or removes a worktree at the end of a run. Prints one JSON
object, `{"path": "<absolute path>" | null, "reused": bool, "legacy": bool, "ffSkipped":
bool}` — `path` is `null` only for `review --reclaim-only`, `reused` / `legacy` are
`false` in review mode, `ffSkipped` is `true` only for a reused fix worktree left
unmoved. Exits `0` on success, `1` on a git failure (stderr names the command), `2` on bad
arguments (unknown mode, a missing positional, a non-numeric `<n>` / `<pr>`, `--base` or
`--reclaim-only` in the wrong mode). Callers: `kp-do-gh-task` §3, `kp-fix-pr` §2 and
`kp-review-gh-pr` §3; `tests/worktree/run.sh` is its offline fixture.

## `scripts/branch-cleanup.sh`

`branch-cleanup.sh <branch>` — run with the primary checkout as the working directory,
after the PR on `<branch>` merged; deletes that local branch, which a squash merge leaves
unmerged in git's eyes and `git worktree remove` keeps. It first runs `git worktree
prune`, so a worktree whose directory is gone no longer counts. A linked worktree that has
`<branch>` checked out is removed when its `git status --porcelain` is empty, else kept
with the branch. The delete is `git branch -D`; the remote is never touched (GitHub's
`delete_branch_on_merge` and `--delete-branch` own it).

Every exit-`0` path prints one line `branch=<branch> result=<r>`: `deleted`,
`deleted-after-worktree-remove:<path>`, `absent` (no `refs/heads/<branch>`),
`kept-dirty-worktree:<path>` or `kept-unreadable-worktree:<path>` (its status failed),
the last two leaving branch and worktree as they were. Exit `2` (nothing on stdout, one
stderr line): not exactly one argument, a name `git check-ref-format --branch` rejects,
run from a linked worktree, or `<branch>` is the default branch (`origin/HEAD`, else
`main`) or the checkout's current branch. Exit `1`: any other git failure. Caller:
`pr-loop.sh`'s close-out; `tests/branch-cleanup/run.sh` is its offline fixture.

## `scripts/repo-roots.sh`

`repo-roots.sh [--spec-dir <dir>] [--spec-files <file>…] [--ref <branch>]`, run from the
run's repo root —
validates the routed clones `.claude/spec-sync.json` names and pins the spec commit. Every
object-valued `requirementRepos` entry is an area: its `path` must be a work tree whose
configured `remote.origin.url` names its `repo` (`https://github.com/` or `git@github.com:`
form, trailing `.git`, case ignored) and must fetch; the branch read, its SHA and the code
root `fresh-checkout.sh` prints are recorded. That branch is the milestone branch when the
unit has one and it exists, else the default branch: with `--ref <branch>` (callers pass
`release/M<k>`, validated like `fresh-checkout.sh`'s), an area whose `origin/<branch>`
exists after the fetch reports `branch` = `<branch>` and its SHA, and one without reports
its default branch and SHA, with `fresh-checkout.sh`'s fallback line on stderr. `--ref`
reaches the area clones only, never the spec checkout. The spec repo is config
`specRepo`, else `--spec-dir`'s (default: the root) `origin`; it is fetched, a clean
checkout on its default branch is `pull --ff-only`ed (a failed pull falls through), and
with `--spec-files` those files must not differ from the pinned SHA. Prints
`{"specRepo","specBranch","specSha","areas":[{"area","repo","path","branch","sha","codeRoot"}]}`
— `path` as configured, `codeRoot` absolute, areas in config order. Exits `0` printed, `1`
a failed check (`work-tree`, `origin`, `fetch`, `default-branch`, `fresh-checkout`,
`dirty`) with one stderr line `repo-roots: <area|spec>: <check> failed: <path>` and
nothing on stdout, `2` bad arguments or not run inside a work tree. Called by
`kp-sync-spec-tasks` §0.9–§0.10 (with `--spec-files`) and `kp-backfill-contract`
§0.9–§0.10 (without, so no clean check), each with `--ref release/M<k>` for the current
milestone.

## `scripts/read-context.sh`

`read-context.sh [--code-root <dir>] <owner/repo> <issue>` or
`read-context.sh [--code-root <dir>] --body-file <path> --repo <owner/repo>` — exactly the
context a coding item's body names (`NOTES.md` § *Coding item body*), as plain text blocks
under `===== <kind>: <ref> (<bytes> B) =====`, in this order:

1. `item` — the issue title and body (or the draft body), human-only fence removed;
   comments are never fetched.
2. `goal-frame` — per spec repo, the section whose title starts with `Goals`, from the
   file and SHA of that repo's first `spec:` line; only when a `spec:` line exists.
3. `spec` — one per `spec:` line, that section's lines at its SHA (ranges from
   `spec-index.py`; content cached per SHA under `state/spec-index/content/`).
4. `code` — one per `code:` line, the whole file under `--code-root` (default `.`).
5. `decision` — one per `decision:` line, the issue title and its
   `kp-resolve-spec-decision` §4.6 resolution comment (`Resolved → …` /
   `Closed as won't-do…`), else the latest comment, noted in the header.

It ends with `===== total: <bytes> B, <n> blocks =====`. REST only, 30 s per `gh` call.
Exits `0` when everything resolved; `3` when something did not (unknown anchor, missing
file, no goal frame, malformed context line), still printing everything and each problem
on stderr; `1` on a GitHub or fetch failure, printing no blocks; `2` on bad arguments.

## `scripts/lint-item.py`

`lint-item.py --repo <owner/repo> --body-file <path> [--code-root <dir>]` — checks a draft
coding item against `NOTES.md` § *Coding item body* before it is filed. The body's own
`spec:` lines name the spec repo and SHA; no config is read. One `FAIL <rule>: <detail>` line
per problem:

- `sections` — Goal, Scope, Out of scope, Context, Acceptance criteria or Verify is missing
  or empty; Rules too, when the body quotes spec text.
- `ac-proof` — an acceptance criterion has no `— proof:` part.
- `context-resolve` — a `spec:` SHA, path or anchor, or a `code:` path under `--code-root`
  (default `.`), does not exist.
- `rules-source` — a Rules quote's `> — <owner/repo>@<sha>:<path>#<anchor>` line does not
  resolve, or the quoted text (whitespace-normalised) is not in that section.

Only for a spec-backed item (a `spec-ref:` marker or any `spec:` line):

- `serves-present` — no `serves:` line under Goal.
- `serves-match` — a `serves:` goal without `via` is not in the `Serves:` list of the section
  `spec-ref:` names (a `REQ-…` key matches a REQ anchor, a `<doc-slug>#<heading-slug>` key a
  heading anchor in the file whose name slugs to `<doc-slug>`; looked up in the loaded files,
  then the whole spec repo at that SHA).
- `spec-gap` — that section has no `Serves:` line; the spec must gain one, the item cannot
  fix it.
- `via-parent` — the parent in `serves: … via <owner/repo>#<n>` does not exist.
- `sweep` — an outgoing ref of a loaded `spec:` section, its child sections included, is not
  covered. Covered means a `spec:` line loads its target, a Rules quote comes from its
  target, a `decision:` line names it, or `dismissed: <key> — <reason>` does; `goal` refs
  always are. An unresolved REQ, `ADR-<n>` or `§n` is also covered when a `spec:` line
  loads that REQ anchor, a section whose anchor starts with `adr-<n>`, or a same-numbered
  section of another file. The key is the target (`<path>#<anchor>`) for a resolved ref and the raw text
  for an unresolved one — a `§n` resolved into its own file is dismissed by target only, so
  dismissing an "Payments spec §8" does not also dismiss the file's own §8. The FAIL line prints
  the key to use.

Then always `INFO bytes=<read-context.sh total> acs=<n> spec-sections=<n>`. REST only, 30 s
per `gh` call. Exits `0` on a pass, `1` on any FAIL, `2` on bad arguments, and `4` on a
GitHub or fetch failure (never reported as a FAIL). The fixtures in `tests/lint-item/`
(`pass-*.md`, `fail-<rule>-*.md`, written against the invented spec in `tests/lint-item/spec/`,
which a stub `gh` serves) run offline with
`kp-gh-lib/tests/lint-item/run.sh`, which also checks exit `4` with `gh` shadowed to fail.

## `scripts/backfill-candidates.sh`

`backfill-candidates.sh --repo <owner/repo> --project-id <id> --sha <synced SHA>
[--labelled]` — the candidate list `kp-backfill-contract` lints (§7.1 steps 2–4, and the
§7.4 stale-label pass's enumeration and status lookup); selection by lint stays in the
skill. It lists with `gh issue list -R <repo> --state open --label type:coding --limit 1000
--json number,title,body,labels`, or with `--labelled` `gh issue list -R <repo> --label
needs-contract --state open --limit 1000 --json number,title,body,labels`. An item carrying
`needs-contract` has its comments read (`gh api --paginate
repos/<repo>/issues/<n>/comments`, REST); `failedAtSha` is `true` when a comment line,
trimmed, equals `<!-- kp-sync-spec-tasks:backfill-failed <sha> -->` (case-sensitive, the full
given SHA), and `false` — with no read — for an item without the label. Without
`--labelled` such an item is `skip: "unchanged-failure"` and is never looked up; with
`--labelled` the flag is only reported. Every other item is looked up with `item-id.sh`
(found through `KP_GH_LIB_BIN`, default the script's own directory) at **1 GraphQL point
per item looked up**: `In progress` or `In review` is `skip: "in-progress"`, any other
status and an item not on the board `skip: null`. It prints one JSON array sorted by
number — `{"number", "title", "body", "labels": [names], "status": "<name>" | null,
"failedAtSha", "skip": null | "unchanged-failure" | "in-progress"}` per listed item,
`status` `null` too for an item never looked up — and `[]` for an empty listing. Exits `0`
listed, `1` when any `gh` call or `item-id.sh` fails (nothing on stdout, its stderr passed
through), `2` on bad arguments, checked before any GitHub call (a missing `--repo`,
`--project-id` or `--sha`, a `--repo` not `<owner>/<name>`, a `--sha` not 7–40 lowercase
hex, an unknown flag). `tests/backfill-candidates/run.sh` is its offline fixture.

## `scripts/report-tokens.sh`

`report-tokens.sh <start-iso> <marker> <owner/repo> <issue-or-pr>` — sums the session's
token usage since `<start-iso>` and records it as this run's row in the table under
`<marker>` on the issue or PR: a re-run with the same start rewrites its own row, any
other run appends one, and a `**Sum**` row totals them. Its columns are `run start
(UTC) | model | effort | input | output | cache write | cache read | subagents | total`:
`effort` is `$KP_EFFORT` when it is a valid level, else `—`; `subagents` sums the
session's `subagents/agent-*.jsonl` transcripts since the start; `total` is the
top-level figures only and excludes `subagents`. The table, its cap and the conversion
of an old single-line or 7-column comment are in `NOTES.md` § *Token-usage report*.

It edits the comment already carrying `<marker>` (found with `--paginate`), otherwise
creates one. Run it from the session's working directory: the transcript is the newest
`*.jsonl` in `~/.claude/projects/<$PWD with / _ . replaced by ->`, else the newest under
`~/.claude/projects/*/`. With no readable transcript the row's figures are `?` and it
still exits `0`. It prints the run's row. `--render <start-iso> <marker>
<transcript.jsonl> <body-file|->` prints the new body offline instead (the fixtures in
`tests/report-tokens/`, run with `kp-gh-lib/tests/report-tokens/run.sh`). REST only — no
GraphQL points.

## `scripts/find-task-pr.sh`

`find-task-pr.sh <owner/repo> <issue>` — a work item's PR, so `kp-do-gh-task-loop` §1.2
and §2 and `item-outcome.sh` no longer restate the lookup:

```json
{"pr": {"number": 183, "state": "MERGED", "isDraft": false,
        "headRefName": "task/182-backfill-second-fold", "mergeStateStatus": "UNKNOWN"},
 "closed": [180]}
```

Branch first: `gh pr list --state all --search "head:task/<n>-"`, filtered to a
`headRefName` starting with `task/<n>-` (`--head` takes an exact name, so a glob matches
nothing). Only when that finds no open or merged PR does it fall back to the issue's
`closedByPullRequestsReferences`, reading each with `gh pr view`. `pr` is the lowest-numbered
open PR, else the lowest-numbered merged one, else `null`; a PR closed unmerged is never
the item's PR, but its number lands in `closed` (ascending) so a caller can tell
`pr-closed` from no PR at all. `{"pr": null, "closed": []}`
is a normal answer with exit `0`; exits `1` on a failed `gh` call and `2` on bad
arguments. The fixtures in `tests/find-task-pr/` run offline against a fake `gh` with
`kp-gh-lib/tests/find-task-pr/run.sh`.

## `scripts/research-prs.sh`

`research-prs.sh <owner/repo> <n> --project-id <ID>` — a research item's research PRs,
each added to the board, so `kp-resolve-spec-research` §6.1.1 calls one script instead of
carrying a `jq` filter and a GraphQL mutation:

```json
[{"number": 41, "url": "https://github.com/example-org/shop-tools/pull/41",
  "boardItem": "PVTI_lAHOACn5E84Bi0Mkzg…"},
 {"number": 43, "url": "https://github.com/example-org/shop-tools/pull/43", "boardItem": null}]
```

Selection: one `gh pr list --state open --limit 100`, keeping a PR whose `headRefName`
starts with `research/<n>-` or whose body references `#<n>` not followed by a digit, and
dropping one whose body carries a closing keyword (close/closes/closed,
fix/fixes/fixed, resolve/resolves/resolved, any case, then whitespace, then `#<m>`) naming an `<m>` other than `<n>`.
Each kept PR, in ascending number, gets the 1-point `addProjectV2ItemById` mutation, which
returns the existing item when the PR is already on the board. A failed add is
best-effort: its `boardItem` is `null`, one stderr line names the PR, and the exit stays
`0`. `[]` is a normal answer with exit `0`; exits `1` when the `gh pr list` call fails and
`2` on bad arguments. The fixtures in `tests/research-prs/` run offline against a fake
`gh` with `kp-gh-lib/tests/research-prs/run.sh`.

## `scripts/linked-item.sh`

`linked-item.sh <owner/repo> <pr>` — the work item a PR belongs to, so
`kp-do-gh-pr-loop-all` §1, `kp-fix-pr` §1 and `kp-review-gh-pr` §1 no longer restate the
lookup:

```json
{"issue": 182, "via": "closes", "decision": null, "decisions": [], "referenceOnly": false}
```

One `gh pr view --json body,headRefName`; the human-only fence is dropped from the body
first (an unclosed one runs to the end of the body). Then, first match wins:

1. **`closes`** — the first GitHub closing keyword (`close`/`closes`/`closed`, `fix`/
   `fixes`/`fixed`, `resolve`/`resolves`/`resolved`, any case) on a same-repo `#<n>`, in
   body order. A cross-repo `owner/repo#<n>` does not match.
2. **`branch`** — a `task/<n>-*` head branch.
3. **`spec-pr`** — a `spec/resolve-<n>` head branch whose body carries
   `Refs <owner>/<repo>#<n>` with the same `<n>` (whole number, so `#410` is not `#41`):
   `issue` is `null`, `decision` is `"<owner>/<repo>#<n>"` and `decisions` is
   `["<owner>/<repo>#<n>"]`.
4. **`spec-pr` (batch)** — a `spec/resolve-<n>-batch` head branch: a batched spec PR.
   `decisions` is every `## <owner>/<repo>#<n>:` heading in the fence-stripped body
   (exactly two `#`, so a `###` heading never matches), in body order, each kept once
   (`#041` is `#41`); `decision` is the first, and `issue` is `null`. The branch's lead
   `<n>` need not be among them. No such heading is no link.

`decision` is always the first entry of `decisions`. Nothing matching is `{"issue":
null, "via": null, "decision": null, "decisions": [], "referenceOnly": false}`, a normal
answer. Only when `issue` is set does it read the issue (`gh issue view
--json state,labels`): `referenceOnly` is `true` exactly when it is `CLOSED` and labelled
`type:research` (`kp-do-gh-pr-loop` §1). Exits `0` answered, `1` on a failed `gh` call,
`2` on bad arguments. The fixtures in `tests/linked-item/` run offline against a fake
`gh` with `kp-gh-lib/tests/linked-item/run.sh`.

## `scripts/item-outcome.sh`

`item-outcome.sh <owner/repo> --issue <n> --project <owner/number>` or
`item-outcome.sh <owner/repo> --pr <p>` — what a child run left behind, read from GitHub
state and never from the child's log, so `kp-do-gh-ready-items` §3.2,
`kp-do-gh-task-loop` §3, `kp-do-gh-pr-loop-all` §2 step 3,
`kp-resolve-spec-decision` §4.7 and `kp-resolve-spec-decision-auto` §4.4 no longer
restate the ladder. The capacity check stays in each caller and runs first; the script
has no `capacity-limit` outcome. It prints one line, `outcome=` first and then only the
keys that outcome sets, always in the order `pr=`, `decision=`, `mergeStateStatus=`,
`blocker=`, `milestone=`:

```
outcome=parked pr=183 mergeStateStatus=BLOCKED
```

`--issue`, first match wins (`pr` and `closed` are `find-task-pr.sh`'s; "no PR" means
`pr` is `null` and `closed` is empty):

1. `pr` is `MERGED` → `merged pr=<p>`;
2. the item carries `needs-contract` → `needs-contract` (`pr=` when there is one);
3. `find-blocking-decision.sh <R> --issue <n>`, plus `--pr <p>` and the body's
   `--spec-ref` from outside the human-only fence when present, finds one →
   `blocked-on-decision decision=<d>` (`pr=` when there is one);
4. no PR, and `milestone-gate.sh` reports `waitingOn` →
   `waiting-on-milestone milestone=M<k>`;
5. no PR, and `blocker-state.sh` has a not-done `laterMilestone` blocker →
   `stalled-cross-milestone blocker=<owner/repo>#<m>` (the first such);
6. no PR, and it has any not-done blocker → `blocked-on-dependency blocker=…` (the
   first);
7. `pr` is `OPEN` → `parked pr=<p> mergeStateStatus=<value>`;
8. `pr` is `null` and `closed` is non-empty → `pr-closed pr=<highest closed>`;
9. otherwise → `build-failed`.

`--pr`, from `gh pr view <p> --json state,mergeStateStatus`: `MERGED` → `merged`;
`OPEN` and `find-blocking-decision.sh <R> --pr <p>` finds one → `blocked-on-decision`;
`OPEN` otherwise → `parked` with `mergeStateStatus`; `CLOSED` → `pr-closed` — each with
`pr=<p>`. The `--pr` form never runs `milestone-gate.sh` or `blocker-state.sh`.

It calls its four siblings — `find-task-pr.sh`, `find-blocking-decision.sh`,
`milestone-gate.sh`, `blocker-state.sh` — next to itself. Exits `0` with an outcome, `1`
when a `gh` call or a sibling failed (its stderr passed on, prefixed `item-outcome.sh:`,
and stdout empty), `2` on bad arguments (exactly one of `--issue` / `--pr`; `--project`
required with `--issue`, rejected with `--pr`). The fixtures in `tests/item-outcome/`
run offline against stub siblings and a fake `gh` with
`kp-gh-lib/tests/item-outcome/run.sh`.

## `scripts/blocker-state.sh`

`blocker-state.sh <owner/repo> <issue>` — the state of every `blocked-by:` blocker of an
item, so `kp-do-gh-task-loop` §1.4 and `kp-do-gh-ready-items` §2.2, §2.3, §3.2 and §3.3
no longer restate the lookups and the milestone comparison:

```json
[{"blocker": "example-org/shop-tools#20", "kind": "issue", "state": "OPEN", "done": false,
  "milestone": "M10", "laterMilestone": true, "inFlight": false}]
```

It reads the item's body (`gh issue view --json body`), strips the human-only fence and
collects its `blocked-by:` lines — a bare `#m` is in `<owner/repo>`, a qualified
`<o>/<r>#m` in `<o>/<r>`, a repeated blocker kept once — then prints one entry per
blocker in first-appearance order. No blocker prints `[]` after that one call. Otherwise
it runs `milestone-of.sh` once for the item and, per blocker, `milestone-of.sh` (its
`state` and milestone) and `gh issue view --json url` (a `/pull/` URL is a pull request),
plus `find-task-pr.sh` for an open issue blocker only.

- `blocker` — always repo-qualified. `kind` — `issue` or `pr`. `state` — `milestone-of.sh`'s:
  `MERGED` only for a pull request, whose `CLOSED` is closed unmerged.
- `done` — an issue once `CLOSED`, a pull request only once `MERGED`: an open PR and one
  closed unmerged both keep the item waiting.
- `milestone` — the blocker's `M<k>`, or `null`.
- `laterMilestone` — an open issue (never a pull request) where the item and the blocker
  both have a milestone and the blocker's ranks later, numerically (M10 after M9); an
  edge with a milestone on one end only is never one.
- `inFlight` — not done, and an open pull request, or an open issue whose
  `find-task-pr.sh` `pr` has `state: "OPEN"`.

Exits `0` when it reported, `1` (stdout empty, a `blocker-state.sh:` stderr line carrying
the failing command's stderr) when the body read, a `milestone-of.sh` call, a URL read or a
`find-task-pr.sh` call failed, and `2` on bad arguments. The fixtures in
`tests/blocker-state/` run the real sibling scripts offline against a fake `gh` with
`kp-gh-lib/tests/blocker-state/run.sh`.

## `scripts/find-blocking-decision.sh`

`find-blocking-decision.sh <owner/repo> [--issue <n>] [--pr <p>] [--spec-ref <s>]
[--from-file <json>]` — the open human-gated issue blocking a work item, its PR or its
`spec-ref`, so `pr-loop.sh`, `kp-do-gh-task-loop` §1.3 and §3 and `kp-do-gh-pr-loop-all`
§2 no longer restate the search:

```json
{"decision": 105, "all": [105, 110]}
```

At least one target flag is required. Each target is one `find-marker.sh <owner/repo>
blocks <target> --state open` call — `#<n>` for `--issue`, `#<p>` for `--pr` (so both
`#<n>` and `<owner/repo>#<n>` match, never `#<n>0`), the value verbatim for
`--spec-ref` — so the human-only fence and `<details>` handling are `find-marker.sh`'s. A
hit is kept only when it is labelled `type:decision`, `type:question` or `type:conflict`.
`decision` is the lowest kept number (`null` when none) and `all` every kept number,
ascending, without duplicates. Exits `0` when it searched (including no hit), `1` when a
`find-marker.sh` call failed (its stderr passed on), `2` on bad arguments. `--from-file`
is passed through to every `find-marker.sh` call; the fixtures in
`tests/find-blocking-decision/` use it and run offline with
`kp-gh-lib/tests/find-blocking-decision/run.sh`.

## `scripts/spec-pr-check.sh`

`spec-pr-check.sh <owner/repo> <pr> --decision <owner/repo>#<n>` — whether a spec PR
`kp-resolve-spec-decision` §4.7 opened is structurally clean enough to merge on its fast
path, without the review ⇄ fix loop. Read-only. Each `spec-ref:` key of the decision is
resolved through `spec-index.py` at the PR's base and head, the way `lint-item.py`
resolves one, and checked against the PR's diff. Prints `ok`, or one
`FAIL <rule>: <detail>` line per problem:

- `untouched-ref` — a `spec-ref:` section has no changed line, or is gone at the head;
- `no-backref` — a touched section carries no `decided in <owner/repo>#<n>` ref to the
  decision;
- `identity` — a `spec-ref:` section's heading (level, number, title) changed;
- `outside-spec` — a changed file matches none of the spec globs, read from the
  default branch's `.claude/spec-sync.json` (never the PR head), else the defaults;
- `ci` — a check at the head is not `pass` or `skipping`, pending included; no checks
  at all passes.

Exits `0` ok, `1` on any `FAIL`, `2` on bad arguments and `4` on a GitHub or fetch
failure. `--from-file <dir>` reads every input from files instead; the fixtures in
`tests/spec-pr-check/` run offline with `kp-gh-lib/tests/spec-pr-check/run.sh`.

## `scripts/spec-pr-fastmerge.sh`

`spec-pr-fastmerge.sh <spec-repo> <pr> --decision <owner/repo>#<n> [--decision
<owner/repo>#<n>]… --checked-head <40-hex sha> --key <spec-ref key> [--key <k>]… --read
<answer>` — `kp-resolve-spec-decision` §4.7's fast path from the sonnet read's answer to a
posted approval, for one decision's spec PR or a batch PR (one `--decision` per folded
decision). `--checked-head` is the head the read saw, a full 40-hex SHA. Steps, in order,
the first fallback stopping the run:

1. `--read` not exactly `ok` → `fallback: read: <answer>`, no GitHub call.
2. `gh pr checks --watch --interval 60`, killed after 540 s: timed out or exit 8 →
   `fallback: ci pending`. `no checks reported`, or any other exit, goes on — step 3
   fails a red check as `FAIL ci`.
3. `spec-pr-check.sh` once per `--decision`, in argument order; the first that does not
   exit 0 stops the run and later decisions are not checked: exit 1 →
   `fallback: spec-pr-check <owner/repo>#<n>: <FAIL lines joined with " | ">`, any other →
   `fallback: spec-pr-check <owner/repo>#<n> exit <code>: <first stderr line>`.
4. `headRefOid` re-read: a failed read → `fallback: head read failed`; a different head →
   `fallback: head moved <checked 7>..<head 7>`.
5. `gh pr comment --body-file` the approval → `approved <checked-head>`; a failed post →
   `fallback: comment failed: <first stderr line>`.

The approval is the verdict comment `guard_merge.py` reads (marker, `verdict: APPROVED`,
`approved: <checked-head>`), its acceptance basis one `Decision <owner/repo>#<n>` line per
`--decision`, then one `spec-ref: <key>` line per `--key`, both in argument order, and no
`body-sha256:` line. It posts the approval but never lands the PR: the merge stays the
skill's own `Bash` call, where `guard_merge.py` sees it. Prints exactly one stdout line.
Exits `0` approved, `3` fallback, `2` on bad arguments (nothing posted, no `gh` call).
`spec-pr-check.sh` is found through `KP_GH_LIB_BIN`, default the script's own directory.
The fixtures run offline with `kp-gh-lib/tests/spec-pr-fastmerge/run.sh`.

## `scripts/spec-branch.sh`

`spec-branch.sh prepare --spec-repo <owner/repo> --issue <n> [--batch]` and
`spec-branch.sh publish --spec-repo <owner/repo> --issue <n> (--target-repo <owner/repo> |
--batch) --title <t> --body-file <f>` — `kp-resolve-spec-decision`'s spec-update branch,
set up and published the same way on every run (*Spec-update worktree flow* steps 2 and 5,
*Batch run* steps 2 and 4). Run from the spec repo's primary checkout; `<top>` is its
`git rev-parse --show-toplevel`.

- `<repo-name>` — the last path component of `git remote get-url origin`, `.git` removed.
- `<base>` — `git symbolic-ref --short refs/remotes/origin/HEAD` without `origin/`, start
  point `origin/<base>`; without that ref, `git rev-parse --abbrev-ref HEAD`, start point
  `<base>` itself.
- `<branch>` / `<worktree>` — `spec/resolve-<n>` in `<parent of top>/<repo-name>-spec-resolve-<n>`;
  with `--batch`, `spec/resolve-<n>-batch` in `<parent of top>/<repo-name>-spec-resolve-<n>-batch`.
  `<legacy>` is `<parent of top>/spec-resolve-<n>`, single mode only, and never created.

**prepare** removes (`--force`) `<worktree>` and `<legacy>` when this checkout's `git
worktree list` has them — never any other path. When `<branch>` exists locally and the
highest-numbered PR on it (`--state all`) is `MERGED`, it deletes the branch locally and
on `origin` (when there), so it counts as absent. It then adds `<worktree>` on `<branch>`,
new from the start point or the existing branch, and prints
`{"worktree": "<worktree>", "branch": "<branch>", "base": "<base>", "reusedBranch": true|false}`.

**publish** first refuses, leaving the worktree in place: an unreadable body file; without
`--batch`, a missing `--target-repo` or a body not naming `<target-repo>#<n>`; with
`--batch`, a `--target-repo` or a body with no `## <owner/repo>#<n>: ` line; a `<worktree>`
this checkout does not list; uncommitted changes in it. It then pushes `<branch>`, reuses
an open PR on it or runs `gh pr create --base <base>`, always removes `<worktree>` (after
a failed push or create too), and prints `{"pr": <number>, "url": "<url>", "created":
true|false}`.

Exits `0` done, `1` a `git` or `gh` call failed (nothing on stdout, its stderr passed
through), `2` bad arguments or a failed precondition. The fixtures run offline against a
local bare repo and a fake `gh` with `kp-gh-lib/tests/spec-branch/run.sh`.

## `scripts/pr-verdict-state.sh`

`pr-verdict-state.sh <owner/repo> <pr> [--history] [--reviews]` — one PR's review-verdict state, read
from its issue comments in one call, so `kp-review-gh-pr`, `kp-fix-pr` and
`kp-do-gh-pr-loop` no longer page through every comment and parse it in prose:

```json
{"head": "f23e59a…",
 "verdict": {"id": 5699700124, "verdict": "APPROVED", "reviewed": "f23e59a…",
             "atHead": true, "createdAt": "…", "updatedAt": "…"},
 "denial": {"id": 5699061946, "reviewed": "9fe2dce…", "createdAt": "…", "updatedAt": "…",
            "findings": "**Blockers**\n- …", "count": 9, "fingerprint": "4ec8fd8…",
            "bySeverity": {"blockers": 0, "major": null, "minor": null, "nits": null,
                           "ci": 0, "combined": null}},
 "fixSummary": {"id": 5699417811, "createdAt": "…", "updatedAt": "…", "body": "…"},
 "rounds": {"verdicts": 2, "denials": 1, "fixSummaries": 1}}
```

`verdict` is the latest comment carrying `<!-- kp-review-gh-pr:verdict -->` and `denial`
the latest one requesting changes, both by `updated_at` — the key the calling skills
already used. The reviewer marks both outcomes with that marker, so a comment is an
approval only when it carries a `verdict: APPROVED` line; anything else, including the
pre-2026-09 format with no `verdict:` line at all, is a denial. The head-SHA line is
`approved:` on an approval and `reviewed:` on a denial, and either lands in `reviewed`,
the head the verdict was made against; `atHead` says whether that is still the PR's head.

`findings` is the `### Findings (for the build agent)` section alone, `count` its
top-level bullets and `fingerprint` its whitespace-normalised sha256 — the
`kp-do-gh-pr-loop` Loop-policy definitions, so the human TL;DR can never reach them.
`bySeverity` counts the bullets under each bold group: `blockers` and `ci` are always
numbers, while `major`/`minor`/`nits` are filled only when the body lists them as
separate groups and `combined` only under the legacy joint `**Major / Minor / Nits**`
heading. A body predating the §6 template scores every group `0`/`null`.

`fixSummary` is the latest `<!-- kp-fix-pr:summary -->` comment **newer than** `denial`,
else `null` — so `kp-fix-pr`'s "already addressed, awaiting re-review" stop is one field.

`--history` adds `history`, every verdict and fix summary oldest to newest by creation
time with its own `body` and `findings`: `kp-review-gh-pr` needs the whole run of rounds,
not just the latest, to honour its do-not-re-raise rule. Every `body` arrives with the
`<!-- human-only:start … -->` fence and `### TL;DR (for humans)` already stripped.

Formal reviews (`/pulls/<n>/reviews`) are read only under `--reviews`, which adds two
keys and leaves every other one unchanged:

```json
{"latest": {"channel": "review", "verdict": "REQUEST_CHANGES",
            "at": "2026-09-12T09:00:00Z", "id": 902},
 "fixNeeded": true}
```

`latest` is the newer of the newest formal review whose `state` is `APPROVED` or
`CHANGES_REQUESTED` (by `submitted_at`; `CHANGES_REQUESTED` reads as `REQUEST_CHANGES`,
and `COMMENTED`, `DISMISSED` and `PENDING` are ignored) and `verdict` (by `updatedAt`),
or `null` when neither exists. The review wins only when it is strictly newer — on a tie
the comment wins, the rule `pr-loop.sh` `classify_review` applies. `id` is the review's
or the comment's, so `kp-fix-pr` can fetch a formal denial's body. `fixNeeded` is `true`
only when `latest.verdict` is `REQUEST_CHANGES` and no fix summary has an `updatedAt`
strictly newer than `latest.at` — `kp-fix-pr` §1.2's whole stop rule.

REST only — no GraphQL points — 30 s per `gh` call. Exits `1` on a GitHub failure and `2`
on bad arguments. `--from-file <fixture.json>` reads `{"head": …, "comments": [...]}`
instead of calling GitHub, plus an optional `"reviews"` array in the REST shape (`id`,
`state`, `submitted_at`, `body`) that `--reviews` reads — a missing key is `[]`; the
fixtures in `tests/pr-verdict-state/` run offline with
`kp-gh-lib/tests/pr-verdict-state/run.sh`, each diffed against its `*.expected.json`
and, under `--reviews`, its `*.reviews.expected.json` when it has one.

## `scripts/review-scope.sh`

`review-scope.sh <owner/repo> <pr> <issue|-> <headRefName> [--state-file <json>]
[--body-file <file>]` — `kp-review-gh-pr` §1.5's item-body hash and §1.7's re-review
scope, in one call. Run it from the checkout whose `origin/<headRefName>` §0.2 fetched;
`<issue>` is the linked coding item, `-` for a spec PR or a PR with no linked issue.
Prints exactly three lines:

```
scope: fix-diff                     | scope: full (<reason>)
reviewed: <sha>                     | reviewed: -
bodySha: <64 hex>                   | bodySha: -
```

`<reason>` is the first failed condition, in order: `no prior denial` (the newest verdict
in `history` is not a denial with a `reviewed` SHA), `no fix push` (no newer fix summary
carries a `pushed:` line), `reviewed not an ancestor` (`git merge-base --is-ancestor
<reviewed> origin/<headRefName>` exits non-zero), `fix outside flagged files` (a path in
`git diff --name-status <reviewed>..origin/<headRefName>`, both sides of a rename, is
neither a `path:line` file the denial's findings flag nor a test file), `no body hash` (no
issue, or the denial has no `body-sha256:` line), `item body changed` (that hash differs
from the current one). `reviewed:` is the denial's SHA whenever the first condition held.
`bodySha:` is printed on every round: the SHA-256 of the body after `body-parts.py strip`,
byte-identical to the one-liner every earlier verdict's `body-sha256:` came from.

`--state-file` is the saved stdout of `pr-verdict-state.sh <owner/repo> <pr> --history`
(only `history` is read); without it the script makes that call. `--body-file` stands in
for `gh issue view <issue> --json body -q .body`. Exits `0` decided (either scope), `1` a
`gh` read, `pr-verdict-state.sh` or the `git diff` failed, `2` bad arguments. The fixtures
in `tests/review-scope/` build a throwaway git repo and run offline with
`kp-gh-lib/tests/review-scope/run.sh`.

## `scripts/post-verdict-comment.sh`

`post-verdict-comment.sh <owner/repo> <pr> --kind verdict|fixSummary --body-file <file>` —
the one writer of a `kp-review-gh-pr` verdict comment and a `kp-fix-pr` fix summary:
it decides whether the body `PATCH`es a true re-run of the latest one or stacks a new
round, and posts the file's bytes unmodified. The body's header is validated first: a
verdict opens with `<!-- kp-review-gh-pr:verdict -->`, a `verdict: APPROVED` or `verdict:
REQUEST_CHANGES` line, then `approved: <sha>` or `reviewed: <sha>` to match; a fix
summary opens with `<!-- kp-fix-pr:summary -->`, then `pushed: <sha>`. State is one
`pr-verdict-state.sh <owner/repo> <pr> --history` call (through `KP_GH_LIB_BIN`), and the
body's `<sha>` must be its `.head`.

- **verdict** — `PATCH` the last `verdict` entry of `.history` only when its body holds
  the body file's `verdict:` and SHA lines, each as a whole line, and no `fixSummary`
  entry was created after it; otherwise create.
- **fixSummary** — `PATCH` `.fixSummary` (the latest summary newer than the latest
  denial) only when its body holds `pushed: <head>` as a whole line; otherwise create.

Prints `{"action": "patched"|"created", "id": <comment id>}`. Exits `0` posted, `1` a
GitHub call failed (the state read or the write), `2` bad arguments or a malformed body,
and `3` when the body's SHA is not the PR head (`head moved: body <sha>, head <head>` on
stderr, nothing posted). The fixtures run offline with
`kp-gh-lib/tests/post-verdict-comment/run.sh`.

## `scripts/decision-state.sh`

`decision-state.sh <owner/repo> <n> [--from-file <json>]` — a human-gated item's comments,
classified in one call, so `kp-resolve-spec-decision` §3, `kp-resolve-spec-decision-auto`
§2 and `kp-resolve-spec-research` §3.1/§4.3 read the same marker rules instead of three
prose copies:

```json
{"cutoffId": null,
 "agent": {"id": 5701, "skill": "kp-resolve-spec-decision-auto", "url": "…"},
 "session": null,
 "latest": "agent",
 "humanCandidates": [{"id": 5703, "url": "…", "body": "B"}],
 "noDecision": {"id": 5690, "url": "…", "newerDecision": true},
 "findings": null}
```

A marker counts only as a whole trimmed line, and "latest", "after" and "newer" order by
`created_at`, ties broken by comment `id`.

- `cutoffId` — the latest `<!-- kp-resolve-spec-decision:restored -->` comment. Every
  field except `noDecision` considers only comments after it (all comments when null), so
  an answer given to a goal question is never read as a decision on the restored item.
- `agent` — the latest `<!-- decision-source: kp-<skill> -->` comment; `skill` is the
  full `kp-…` name (`kp-resolve-spec-decision-auto`, a creating skill, or
  `kp-resolve-spec-research`).
- `session` — the latest `<!-- decision-source: claude-code-session -->` transcription,
  with its `body`.
- `latest` — `agent` or `session`, whichever was posted later; null when both are.
- `humanCandidates` — every comment after the newest of cutoff, `agent` and `session` that
  is not skill output and not by a `user.type` `Bot` author, oldest first, with its
  `body`. Skill output has a line containing `<!-- kp-` or `<!-- decision-source:`, or a
  first non-blank line starting `Resolved →`, `Closed as won't-do` or `Goal recorded →`.
  Whether a candidate picks an outcome is the caller's judgment, never the script's.
- `noDecision` — the latest `<!-- kp-resolve-spec-decision:no-decision -->` comment over
  **all** comments; `newerDecision` says `agent` or `session` was posted after it.
- `findings` — the latest `<!-- decision-source: kp-resolve-spec-research -->` comment.
  It is also `agent` until a later agent decision lands, so callers read the findings
  comment from here, never from `agent`.

One paginated REST read of `repos/<owner/repo>/issues/<n>/comments` — no GraphQL points —
30 s per `gh` call. Exits `0` on a read (including no comments), `1` on a GitHub failure
and `2` on bad arguments. `--from-file <fixture.json>` reads `{"args": [...], "comments":
[<REST comment objects>]}` instead of calling GitHub; the fixtures in
`tests/decision-state/` run offline with `kp-gh-lib/tests/decision-state/run.sh`, each
diffed against its `*.expected.json`.

## `scripts/run-child.sh`

```
run-child.sh --log <path> --cwd <dir> [--model <m>] [--effort <level>] [--timeout-min <n>] [--chrome] -- <prompt>
run-child.sh --wait <log> [--wait-max-sec <s>]
run-child.sh --list
```

Launches a headless `claude -p` child with the family's standard flag set
(`--permission-mode bypassPermissions --autocompact 150k --settings
scripts/headless-settings.json`, plus `--model` when given and `--chrome` when given, for a
child that drives Claude in Chrome) and waits for it in the
**foreground** — the launch-detached / poll-a-sentinel dance `kp-do-gh-pr-loop` and
`kp-do-gh-task-loop` used to restate in prose (`NOTES.md` § *Waiting in a headless
session*). The launch call returns as soon as the child is detached:

```
status: running log=/…/pr-loop-shop-app-88-cycle1.log
```

Every path is derived from `<log>` — the child's output and its `<log>.exit` sentinel —
so nothing has to survive between the caller's `Bash` calls; a fresh `<log>` per launch,
since the sentinel of a reused one is cleared only by the launcher. Each `--wait` is an
ordinary foreground `Bash` call (`timeout: 540000`) that returns inside `--wait-max-sec`
(default 480) either with the child's result line:

```
exit=0 capacity=session-limit reset='resets 2:30am (Europe/Berlin)' log=/…/build.log
```

or with the same `status: running` line, in which case the caller issues the identical
wait again. `capacity` is the Claude usage limit the child's log reports — `none`,
`session-limit` or `weekly-limit`: a quota-killed child exits 0 without touching GitHub,
so its caller must tell that from real work, and a negated mention ("no child hit the
usage limit", a parent's own report quoted into the log) is not a hit. `--timeout-min`
(default 120) kills a child that overruns. Every child runs with `KP_HEADLESS_CHILD=1`
in its environment, so `kp-msg-me/scripts/send.sh --session-end` drops a child's
wrap-up message (`NOTES.md` § *Operator notifications*). It also gets
`KP_CHILD_LOG=<log>`, so a lock the child takes can name its log.

`--model` takes a model alias, a full model name or a tier, split by
[`model-label.sh`](#scriptsmodel-labelsh): `--model opus-high` launches the child with
`--model opus --effort high`. `--effort <level>` (`low`, `medium`, `high`, `xhigh` or
`max`) sets the reasoning effort and always wins over a tier suffix. When an effort
results, the child gets `--effort <level>` and `KP_EFFORT=<level>` in its environment;
with none, neither is added and the command line is the same as without the option. The
CLI only warns on an unknown `--effort` value and runs at the default, so the level is
checked here: an invalid `--effort`, an empty `--effort ''` or `--model ''`, or a tier
with no model part (`-high`) is exit `2` before anything is detached or the log created.

Every child also carries a unique `KP_RUN_ID`, which everything it starts inherits,
`nohup … &` jobs included. Claude Code gives those their own process group and they are
reparented to PID 1, so a group or tree kill misses them. On timeout, and again when the
child exits, every process carrying the id gets TERM and, after 10 s, KILL. That way a
killed child's detached build can't run on into the next attempt. Gradle daemons and
workers (`GradleDaemon`, `GradleWorkerMain`) are spared, since a daemon may be serving
another session's build. Killing the child's `gradlew` client is what cancels its build.

Every child is registered while it runs, in `${KP_CHILDREN_DIR:-$HOME/.claude/kp-children}`
(the override keeps tests out of the real home). The detached wrapper writes
`<registry>/run-child-<pid>-<epoch>` right after starting the child, through a dot-file
tmp and `mv`, one `key=value` per line: `pid` (the wrapper), `child`, `started` (UTC),
`started_epoch`, `cwd`, `log` and `prompt` (newlines and tabs turned into spaces). A failed
registration is noted in `<log>` and never stops the child. The entry is removed just
before the `<log>.exit` sentinel is written, so a returned `--wait` never sees it, and by
an `EXIT` trap when the wrapper exits early. `run-child.sh --list` prints one line per live
entry, oldest first:

```
pid=41234 elapsed=1d01:01:01 cwd=/…/shop-app-91 log=/…/ready-items.log prompt=/kp-do-gh-ready-items --project example-org/1
```

`elapsed` is `HH:MM:SS`, prefixed with `<days>d` from a day on; the prompt is cut at 80
characters with `…`. With no live entry it prints `no live children`. An entry whose
`pid` is missing or dead (a SIGKILLed wrapper) is pruned; an unreadable registry
directory is exit `1`, and extra arguments exit `2`.

A detached child outlives the session that launched it: it keeps working until it
finishes or its `--timeout-min` fires, and shows up in ListAgents only as an
"interactive", possibly "busy", peer named after its working directory — easy to
mistake for a session someone else opened. `run-child.sh --list` is how to see it, and
stopping it means killing both the listed `pid` (the wrapper) and the entry's `child=`
pid.

Exit: `0` the child finished (whatever its own exit code, which is in `exit=`) · `3`
still running · `1` launch failure · `2` bad arguments. The fixtures in `tests/run-child/`
cover the report lines, the `--chrome` pass-through, the `KP_HEADLESS_CHILD` and
`KP_CHILD_LOG` markers, `--effort`, a tier suffix and `KP_EFFORT`, the registry and `--list`, and the sweep on exit and on timeout
(against a `claude` stub in `tests/run-child/bin/`) offline with `kp-gh-lib/tests/run-child/run.sh`.

## `scripts/model-label.sh`

```
model-label.sh <tier>
```

Splits a model tier into a model and a reasoning effort and prints exactly one line,
`model=<model> effort=<effort>`. `<tier>` is what follows `model:` in a label (a leading
`model:` is accepted and dropped), or a plain model alias or full model name. When it ends
in `-low`, `-medium`, `-high`, `-xhigh` or `-max` (lower case only), that suffix without
the hyphen is the effort and the rest is the model; otherwise the whole value is the model
and the effort is empty:

| `<tier>` | Output |
|---|---|
| `opus-high` | `model=opus effort=high` |
| `claude-opus-5-5-xhigh` | `model=claude-opus-5-5 effort=xhigh` |
| `model:sonnet` | `model=sonnet effort=` |
| `claude-opus-5-5` | `model=claude-opus-5-5 effort=` |

`run-child.sh` passes its `--model` through it. Exit: `0` printed · `2` bad arguments (none,
more than one, an empty value, or an empty model part such as `-high` or `model:-high`),
with a usage line on stderr. The fixtures run offline with
`kp-gh-lib/tests/model-label/run.sh`.

## `scripts/notes-section.sh`

```
notes-section.sh [--file <path>] <heading>
```

Prints one section of a markdown file — by default `kp-gh-lib/NOTES.md`, found from the
script's own location — so a skill following a `§ *Name*` reference loads that section
instead of the whole file (about 100 KB). A heading line is a `## ` or `### ` line
outside a fenced code block (backtick or tilde; each closes only on its own kind).
`<heading>` matches when the heading text equals it or continues with ` (` — `'Waiting in
a headless session'` finds `## Waiting in a headless session (family convention)`;
comparison is literal and case-sensitive. Output is the heading line through the line
before the next heading of the same or a higher level, so a `##` section includes its
`###` subsections; a `# ` line also ends it and `####` lines are content. For a
`§ *A* → *B*` reference, pass `B`.

Exit: `0` one section printed · `1` no match, or more than one (stdout empty; stderr
lists each matching heading with its line number) · `2` bad arguments (no heading, two,
an unknown option, `--file` without a value) or a file that does not exist or cannot be
read. `kp-do-gh-task`, `kp-fix-pr` and `kp-review-gh-pr` load NOTES sections only
through it. The fixtures run offline with `kp-gh-lib/tests/notes-section/run.sh`.

## `scripts/run-verify.sh`

```
run-verify.sh --log <path> [--tail <n>] [--timeout-sec <s>] -- <command> [args…]
```

Runs one verification command (a test, lint or build) so its output stays out of the
caller's context. The command runs in the current directory with stdin from `/dev/null`;
its stdout and stderr go, merged in arrival order, only to `<path>`, which is truncated
first (its parent directory is created). `--timeout-sec` is an integer 1–540, default
`540`, so the run fits one foreground `Bash` call under the 10-minute cap; on expiry the
command's process group gets TERM, then KILL 5 seconds later. `--tail` is an integer ≥ 1,
default `80`. A repeated option takes its last value.

It prints one result line first:

```
result=<pass|fail|timeout> exit=<code> seconds=<elapsed> lines=<n> log=<path>
```

`exit` is the command's exit code — `124` on timeout, `128 + <signal>` when a signal ended
it, `127` when it is not found and `126` when it cannot be executed (both `result=fail`
with an empty log). `seconds` is whole, rounded down; `lines` counts `str.splitlines()` of
the log. On `pass` nothing else is printed. On `fail` or `timeout` it then prints
`--- last <k> of <lines> lines ---` and the log's last `k = min(tail, lines)` lines byte for
byte — the verbatim failure text the caller reports.

`kp-do-gh-task` §4.3 (log `<scratchpad>/verify-<n>-<k>.log`) and `kp-fix-pr` §3.3
(`<scratchpad>/verify-pr-<n>-<k>.log`) run every verification command through it. Exit:
`0` the command ran or could not be started, whatever its result · `1` the log cannot be
created · `2` bad arguments (no `--log`, no `--` separator, no command, an unknown option,
a missing or out-of-range value), nothing run. The fixtures run offline with
`kp-gh-lib/tests/run-verify/run.sh`.

## `scripts/ci-failure-excerpt.sh`

```
ci-failure-excerpt.sh <owner/repo> <pr> [--lines <n>]
```

Prints a PR's failing CI checks with the failure text, so `kp-fix-pr` §1.4 and
`kp-review-gh-pr`'s CI end check judge a red check without loading a whole log. It reads
the checks once (`gh pr checks --json name,bucket,link,workflow`); a check is failing when
its `bucket` is `fail`. For each failing check whose `link` starts
`https://github.com/<owner>/<repo>/actions/runs/<run-id>/job/<job-id>` it reads
`gh run view <run-id> --job <job-id> --log-failed`. Each `gh` call is bounded to 60 s
(`KP_CI_EXCERPT_TIMEOUT_SECONDS` overrides it, for the fixtures). Per failing check, in
the order `gh pr checks` listed them, blocks separated by one empty line:

```
check: <name>
url: <link>
step: <step of the last log line that has one, or `unknown`>
--- last <k> of <total> failed-step lines ---
<the last k lines, each reduced to its text>
```

`k = min(n, total)`; `--lines` is an integer ≥ 1, default `60`. A log line is
`<job>\t<step>\t<timestamp> <text>`: a leading byte-order mark is dropped, a line with
fewer than two tabs is all text and has no step, and a leading ISO timestamp is stripped
from the text. A failing check whose link is not an Actions job, or whose log call fails,
times out or prints nothing, gets `check:`, `url:` and `log: unavailable (<reason>)`, the
reason one of `not a GitHub Actions job`, `log call failed`, `log call timed out`,
`no failed-step lines`. No failing check prints `no failing checks`.

Exit: `0` printed (also no failing checks, unavailable logs, and `gh pr checks` exiting
`8` while pending or `1` when some failed, both with JSON on stdout) · `1` the checks read
failed — empty or unparseable stdout, or a timeout (stderr carries the message) · `2` bad
arguments (a missing or malformed `<owner/repo>` or `<pr>`, an unknown option, `--lines`
without a value, non-integer or below 1). The fixtures run offline with
`kp-gh-lib/tests/ci-failure-excerpt/run.sh`.

## `scripts/run-lock.sh`

```
run-lock.sh (acquire|release|status) --workspace <dir> <key> [--pid <n>]
```

An exclusive per-key run lock, so two runs never drive the same work item at once.
`kp-do-gh-task-loop` §0.4 acquires `<repo-name>-<n>` for its whole run and releases it in
§4; `kp-do-gh-ready-items` §3.1 and §3.2 read its `status` before launching or judging a
task-loop child. `kp-do-gh-ready-items` §0.4a holds `ready-items-<owner>-<number>` — one
live pass per board — and releases it in §4.

The lock is `<dir>/.kp-locks/<key>.lock`, outside every repo; `<key>` matches
`^[A-Za-z0-9._-]+$`, `<dir>` must exist, and `acquire` creates `.kp-locks/`. The **owner
pid** is `--pid`, else `$CLAUDE_PID` (the Claude CLI process, set in every `Bash` tool
call), else `$PPID` — so a skill's lock lives exactly as long as its session; `--pid` is
for tests and shell-script callers. The file holds `pid=`, `started=` (UTC ISO-8601),
`session=$CLAUDE_CODE_SESSION_ID` and `log=$KP_CHILD_LOG`, written to a tmp file and
hard-linked into place, so it appears atomically and complete. A recorded pid is alive
when `kill -0` succeeds or fails with "Operation not permitted".

| Verb | Output (stdout) | Exit |
|---|---|---|
| `acquire` | `acquired key=<k> pid=<owner>` — the lock was free | 0 |
| | `acquired key=<k> pid=<owner> reentrant` — the owner already holds it; file untouched | 0 |
| | `acquired key=<k> pid=<owner> takeover=<dead pid> stale-since=<started>` — stale lock taken over | 0 |
| | `held key=<k> pid=<holder> started=<t> session=<s> log=<l>` — a live pid holds it; nothing changed | 3 |
| `release` | `released key=<k>` — the owner's lock removed | 0 |
| | `not-held key=<k>` — no lock | 0 |
| | `not-owner key=<k> pid=<holder>` — file untouched | 3 |
| `status` | `free key=<k>` · `held key=<k> pid=… started=… session=… log=…` · `stale key=<k> pid=… started=… session=… log=…` — read-only | 0 |

**Stale takeover.** A lock whose pid is dead, or that has no numeric `pid=` line, is
stale (`takeover=` is then empty). `acquire` moves it to `<key>.lock.stale.<$$>` and
takes over only if the moved content is what it judged dead; if another taker replaced
it meanwhile, it links that lock back (or, when a third taker already created one, drops
the moved copy) and prints `held` for whoever holds it now, exit 3. A takeover also
prints `run-lock.sh: took over stale lock <key> from dead pid <pid>` on stderr. A crashed
or killed session's lock is reclaimed this way by the next `acquire`.

Exit: `0` as above · `1` I/O failure (cannot create the directory, write the tmp file,
read or remove the lock), with `run-lock.sh: <what failed>` on stderr · `2` bad arguments
(unknown verb or flag, missing `--workspace` or key, invalid key, non-numeric `--pid`,
missing workspace dir) · `3` held by another live pid (`acquire`) or not the owner
(`release`). The fixtures run offline with `kp-gh-lib/tests/run-lock/run.sh`.

## `scripts/pr-loop.sh`

```
pr-loop.sh start <owner/repo> <pr> --project <owner/number> [--model <tier>]
           [--stall-limit <k>] [--max-cycles <k>] [--log-dir <dir>] [--dry-run]
pr-loop.sh --wait <state-file> [--wait-max-sec <s>]
```

Runs one PR's review ⇄ fix loop — the policy in `kp-do-gh-pr-loop` § *Loop policy* — so
that skill spends a handful of turns per PR instead of one per child launch, wait and
GitHub read. Same shape as `run-child.sh`: `start` runs the preamble, reads the PR and
its linked item, writes `<log-dir>/pr-loop-<repo-name>-<pr>.state.json` (default
`$TMPDIR/kp-pr-loop`), launches the first `kp-review-gh-pr` child and prints
`status: running state=<file>`. Each foreground `--wait` (`timeout: 540000`) polls the
running child through `run-child.sh`. When the child is done, it checks the child's log
for a usage limit, then classifies the outcome from GitHub state (`pr-verdict-state.sh`,
never the child's stdout). It updates the state file and launches the next phase:
`kp-fix-pr`, another review, or the one `kp-do-gh-pr-loop-escalate` child, handed an
`<…>.evidence.json` file, which raises the human-gated item. The call returns
`status: running` within `--wait-max-sec` (default 480).

The tier — `--model`, else the linked item's `model:*` label value, else `opus` — is
split once in `start` by `model-label.sh` (a failure is exit `1`); the state stores its
`model` and `effort` (`""` when the tier names none; a state file without the key reads
as `""`). Every child runs with `--model <model>`; fix and escalate add `--effort
<effort>`, and the review runs at `high` when that effort is `low` or `medium` and at the
effort itself otherwise. A tier with no effort passes no `--effort` to any child. After
the first stalled fix cycle the loop continues past, the state's `boost` (`xhigh`, or
`max` when the effort is already `xhigh` or `max`) replaces the review and fix effort for
the rest of the loop — escalate keeps the tier's, a no-verdict round never boosts, and a
state file without the key is unboosted; that cycle's row reads `stall → effort
<boost>` and the finished report prints `boost: <boost>` before its terminal line. The
`--dry-run` plan's `model:` line appends ` · effort: <level>`, or ` · effort: default`.

A finished loop prints its cycle table, the close-out result, the child logs and one
terminal line `outcome=<o> [reason='<r>'] [reset='<t>'] state=<file>`. A merge runs the
close-out: it closes the linked issue if it is still open, sets its board item to Done,
and calls `unblock-dependents.sh`. Last, it runs `branch-cleanup.sh` on the PR's head
branch from the primary checkout `start` ran in, recording its result as the close-out's
`branch` key (a state file without `headRefName` skips it). A PR already merged on
entry gets only the close-out and writes no state file. `--dry-run` prints the plan and
writes nothing.

Exit: `0` merged or a dry-run plan · `3` still running · `4` parked (the reason names the
decision issue) · `5` capacity-limit · `1` a failed lookup or launch, state unchanged ·
`2` bad arguments. Siblings are found through `KP_GH_LIB_BIN` (default the script's own
directory); the fixtures in `tests/pr-loop/` replay the loops against fakes offline with
`kp-gh-lib/tests/pr-loop/run.sh`.
