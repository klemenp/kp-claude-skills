# Threat model

What these skills assume about the repositories they run on, and what goes wrong when
that assumption does not hold.

## What is protected

- The operator's machine and credentials: agents run shell commands there with the
  operator's `gh` token.
- The operator's repositories: agents push branches, merge pull requests, close issues
  and edit a spec.
- Confidential project content: specs, issues and code of private projects must not
  leak into anything published.

## Trust assumptions

- Every repository the automation reads or writes is writable only by the operator and
  people the operator trusts. Nobody else can open an issue, comment, review or open a
  pull request there.
- The public copy of this repository is a snapshot, made by
  `.github/scripts/export-mirror.sh` after a denylist check of every exported file. The
  automation never reads it, and it accepts no issues or pull requests.
- The operator's shell is trusted. Nothing here tries to bind it.

## What the automation trusts

The scripts decide from where a piece of text is, not from who wrote it. None of them
checks a comment's or an issue's author. On a repository outsiders can write to, each of
these becomes a way to steer the agents:

- **Verdict and decision comments.** A comment carrying the verdict marker and
  `verdict: APPROVED` with the head commit satisfies the merge gate
  (`.claude/hooks/guard_merge.py`, `pr-verdict-state.sh`). Any person's comment on a
  human-gated item counts as the operator's answer (`decision-state.sh`).
- **Marker lines found by search.** An issue whose body carries the right
  `blocks:`, `spec-ref:` or `parent:` line is found by `find-marker.sh` and can be reused
  as the item a skill was about to create, added to the board, or used to suppress
  filing the real one.
- **A pull request found by name.** A PR is matched to an item by its head branch name
  (`task/<n>-…`) or a closing keyword (`find-task-pr.sh`, `linked-item.sh`). A fork's PR
  with a matching name is not told apart, and `kp-do-gh-pr-loop-all` reviews every open
  PR.
- **Decision text in agent context.** `read-context.sh` loads the latest resolution
  comment of each decision an item names into the builder's and the reviewer's context.

## Headless children

Orchestrators launch each step with `--permission-mode bypassPermissions`, because
nobody is present to approve a tool call. Those children read issue bodies, comments and
review findings and act on them. That text is therefore an instruction channel: whoever
can write it can tell an agent with shell access what to do. This is safe only under the
trust assumptions above.

The skills limit the channel where it is cheap to: a builder or reviewer loads only the
item body and the context it names (`read-context.sh`), never a whole spec or comment
thread, and the human-only fence is stripped before an agent reads a body.

## Known gaps

- **The approval is agent-writable.** GitHub rejects a formal self-review, so on a
  self-authored PR the approval is an ordinary comment that any agent session could
  write. The gate raises the cost of skipping review; it cannot prevent it.
- **The merge gate reads command text.** It misses a merge made through a script file, a
  shell variable holding the program name, backticks, or a quoted string other than
  `bash -c` and `eval` (`CLAUDE.md` § Enforcement).
- **The Bash guard reads command words.** It misses a command built by variable or
  backtick expansion, a heredoc piped into a shell, an alias or script that wraps a
  guarded command, and other deleting tools (`CLAUDE.md` § Enforcement).
- **The denylist checks commits only.** `.githooks/check-denylist.sh` covers staged
  changes and commit messages. Issue, pull-request and comment text is not checked, and
  `--no-verify` skips it.
- **Hooks are local.** They run in a Claude session rooted in this repository and in a
  clone with `core.hooksPath` set. A session rooted elsewhere is not gated.
- **Broad tool permissions.** Several skills allow unrestricted `Bash`, so a skill's
  `allowed-tools` line is not a boundary.

## Conclusion

Do not run these skills against a repository that people you do not trust can write to.
On a private repository with one operator the design is sound: the operator is the only
author of every comment the agents act on. Opening such a repository to the public would
need an author check at every read listed above, which does not exist.
