---
name: kp-check
description: Investigate a suspected issue before anything is filed — restate the suspicion as a falsifiable question, run the investigation read-only in a plan-mode subagent (no edits, no writes, reproduce-only), and adjudicate whether it is a real issue. Only on a confirmed verdict does it print a pasteable kp-create-gh-item command holding the distilled problem statement; on "not an issue" or "inconclusive" it reports the evidence and files nothing. Manual-only.
disable-model-invocation: true
argument-hint: [issue-description] [--repo <owner/name>] [--project <number|owner/number|id>] [--dry-run]
---

# Investigate a suspected issue, file it only if real

The verification front door to `kp-create-gh-item`. Where `kp-create-gh-item` assumes the
work is already known and turns a description into a build-ready item, this skill takes
a **suspicion** — "I think X is broken", "this looks like a leak", "are we double-firing
this webhook?" — and **first establishes whether the issue is real** before anything is
filed. It separates the two judgements the family otherwise collapses: *is there an
issue?* (this skill) and *how do we file it?* (`kp-create-gh-item`).

The investigation runs in a **read-only subagent under plan-mode discipline**: the
subagent may read code, search, run tests, reproduce, and inspect logs/CI to gather
evidence, but it **never edits the working tree and never writes to GitHub or any
remote** — reproduce-only, never fix. Only its distilled verdict returns to the main
thread, keeping the operator's context clean.

`kp-check` runs **inline (no fork)** itself, because §1–§3 talk to the operator. This skill
**owns no issue-creation logic**: when an issue is confirmed it prints a pasteable
`kp-create-gh-item` command for the operator to run, adding nothing to the item beyond the
distilled description it puts in that command.

**Goal (success criteria — loop until all are true):** the suspicion is restated as a
falsifiable question; a read-only subagent has gathered evidence without mutating
anything; the verdict is one of **issue / not-an-issue / inconclusive** with the
evidence that supports it; on **issue**, a pasteable `kp-create-gh-item` command holding
the distilled problem statement has been printed for the operator (run, it files the item
under its own clarity loop); on
**not-an-issue / inconclusive**, the evidence is reported and **nothing is filed**.

## 0. Setup

1. **This run's arguments: `$ARGUMENTS` (empty if none). Parse them.** Everything that is not a flag is the **issue description /
   suspicion** (may be multi-word / multi-line; if it is empty, stop and ask the operator
   for one). `--repo <owner/name>` and `--project <number|owner/number|id>` are
   **pass-through** to `kp-create-gh-item` (§4) — this skill does not resolve them itself.
   `--dry-run` investigates and reports the verdict but files nothing (§3).
2. **Repo guard.** `git rev-parse --is-inside-work-tree` must succeed and `gh` must be
   authenticated (`gh auth status`). If not, stop with a clear message.

## 1. Frame the suspicion (the falsifiable question)

A suspicion you cannot falsify cannot be investigated. Before spawning anything:

1. **Restate the suspicion crisply** and ground it: a quick `Grep`/`Glob`/`Read` to locate
   the symbols / files / endpoints / behavior it points at, enough to charge the subagent
   precisely.
2. **Define what would prove it true and what would prove it false** — the concrete
   observation, repro, test outcome, or log/CI signal that decides it each way. This is
   the subagent's charge.
3. **If the suspicion is too vague to define that question** (anything affecting which
   behavior/interface/scope is even in question), **ask the operator one targeted
   question** (global `CLAUDE.md` §1) and re-evaluate before investigating. Do not spawn a
   subagent on a charge you cannot state — and never invent the missing detail.

## 2. Investigate in a read-only subagent (plan mode)

Spawn **one** subagent to do the investigation. Prefer the **`Plan`** agent type — it can
read, search, and **run** (Bash: tests, repro, log/CI inspection) but has **no
Edit/Write/NotebookEdit**, which is exactly plan-mode discipline. Use **`Explore`** instead
when the question is purely "does the code do X" and no execution is needed.

Charge the subagent explicitly with:

- the **suspicion** and the **falsifiable question** from §1, and the files/symbols it
  points at;
- a hard **read-only mandate**: gather evidence only — **no working-tree edits, no
  commits, no pushes, no GitHub/issue/PR/remote writes**; reproduce, never fix;
- the **structured verdict** to return (self-contained, since only this returns):
  - **`VERDICT`** ∈ `issue` | `not-an-issue` | `inconclusive`;
  - **evidence** — `file:line` references, the repro steps and their actual output, the
    failing/passing test or the log/CI signal that decides it;
  - **root-cause hypothesis** (for `issue`) and **blast radius** — what's affected, how
    severe, how likely to bite;
  - a **one-paragraph problem statement** suitable verbatim as a `kp-create-gh-item`
    task-description (for `issue`);
  - for `not-an-issue`: the observation that **falsifies** the suspicion (so the operator
    can trust the negative); for `inconclusive`: exactly what is missing to decide.

## 3. Adjudicate the verdict

- **`not-an-issue`** → report the falsifying evidence so the negative is trustworthy.
  **Create nothing. Stop.**
- **`inconclusive`** → report what is missing and the next probe that would settle it.
  **Do not file on a guess.** If the operator supplies the missing input (or authorizes a
  deeper/different probe), **loop once back to §2** with the sharper charge; otherwise stop
  with the open question stated. Bounded — re-investigate only on new operator input.
- **`issue`** → surface the verdict, evidence, root-cause hypothesis, and blast radius to
  the operator, then proceed to §4.
- **On `--dry-run`**, stop after presenting the verdict and, for an `issue`, the
  problem statement it **would** file — create nothing.

## 4. Print the pasteable command (only when confirmed)

Only on a confirmed **`issue`** verdict, print this command for the operator to paste and
run, with the §2 one-paragraph problem statement quoted and the `--repo` / `--project`
flags forwarded as given:

```
/kp-create-gh-item "<the §2 one-paragraph problem statement>" [--repo <…>] [--project <…>]
```

When the operator runs it, `kp-create-gh-item` runs its own clarity loop, atomicity
assessment, labels, duplicate check and board add. Then stop.

## 5. Report

Print:
- the **suspicion** and the **falsifiable question** it was reduced to;
- the **verdict** with the key evidence (`file:line`, repro output, test/CI signal);
- on `issue`: the command printed for the operator (on `--dry-run`, the command it would
  print) and a pointer to `kp-create-gh-item`'s own report for the filed item(s);
- on `not-an-issue` / `inconclusive` / `--dry-run`: the reason **nothing was filed**.

No token-usage / `NEW_ITEMS=` lines — this is an interactive single-shot investigator, and
any item it leads to is reported by `kp-create-gh-item`.

## Invariants

- **Verify before filing.** An item is created only on a confirmed `issue` verdict —
  never on a guess, an `inconclusive` result, or a `not-an-issue`.
- **Investigation is read-only (plan mode).** The subagent reads, searches, runs, and
  reproduces but **never edits the working tree and never writes to GitHub/remote** —
  reproduce-only, never fix.
- **Investigation runs in a subagent.** The heavy exploration happens in an isolated
  subagent context; only the distilled verdict returns, keeping the main thread clean.
- **Owns no creation logic.** Filing — body, labels, atomicity, dedup, board adds — happens
  in `kp-create-gh-item`, which the operator runs from the pasteable command; `kp-check`
  only puts the distilled description (and `--repo`/`--project`) into that command.
- **Ask, don't invent.** If the suspicion is too vague to state a falsifiable question,
  ask the operator before spawning the subagent; never assume the missing detail.
- **Bounded loop.** Re-investigate (§2) only on new operator-supplied input or an
  authorized sharper probe — never spin the subagent unattended.
