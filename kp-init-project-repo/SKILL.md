---
name: kp-init-project-repo
description: Turn any existing project folder into a professional, version-controlled repository — auto-detect the tech stack, generate or augment a fitting .gitignore, add a project CLAUDE.md plus standard files (.editorconfig, version pin), set up project-tailored Claude Code hooks in .claude/settings.json (auto-format, destructive-command and sensitive-path guards, optional test/build gates), make the initial git commit, then create a private GitHub repo and push. Use whenever the user asks to "initialize this folder for git", "set up git", "add a gitignore/CLAUDE.md", "add Claude Code hooks", "make this a professional project", or "create a private GitHub repo and push it" — for a codebase in any language (Node, Python, Go, Rust, Java, etc.).
---

# Initialize Project Repository

Take a folder that already contains code but is not yet (fully) under version control, and bring it up to a professional baseline: correct ignore rules, a project `CLAUDE.md`, a couple of standard files, an initial commit, and a private GitHub repo with `main` pushed. Stack-agnostic — it detects what the project is and tailors the generated files.

## When to use

Trigger when the user wants to bootstrap version control / project hygiene for an **existing** folder, e.g.:
- "Initialize this folder for git", "set it up for git".
- "Add a .gitignore / CLAUDE.md for this project."
- "Make this a professional project" / "add the missing files a real project should have."
- "Create a private GitHub repo and push this."

Don't trigger for: scaffolding a brand-new empty project from a template (use a language-specific bootstrap skill), or single-file edits unrelated to repo setup.

## Operating principles

- **Idempotent.** Detect what already exists and skip or augment — never clobber. Safe to re-run after a partial run.
- **Surgical.** Don't reformat or "improve" existing files. Only add what's missing.
- **Never commit secrets.** Ensure `.env*`, key/credential files, and tokens are ignored before the first `git add`. If any look already tracked, stop and warn.
- **Confirm outward-facing actions.** Always confirm repo name + visibility with the user before creating a GitHub repo. Default visibility: private.

## Procedure

### 1. Detect the stack
Look for marker files in the project root and report what you found (with confidence):

| Marker | Stack |
| --- | --- |
| `package.json` (+ `next.config.*` / `react` / `vite` / `angular.json`) | Node / JS-TS (Next, React, Vite, Angular, …) |
| `pyproject.toml`, `requirements.txt`, `setup.py` | Python |
| `go.mod` | Go |
| `Cargo.toml` | Rust |
| `pom.xml`, `build.gradle(.kts)` | Java / Kotlin (Maven / Gradle) |
| `Gemfile` | Ruby |
| `composer.json` | PHP |
| `*.csproj`, `*.sln` | .NET |

Also note the package manager (lockfile: `pnpm-lock.yaml`, `package-lock.json`, `yarn.lock`, `poetry.lock`, `uv.lock`, …) and the runtime version if discoverable. If multiple stacks are present, handle each (monorepo) or ask.

### 2. `.gitignore`
- If one exists, **augment** it: add anything missing for the detected stack plus OS/editor cruft (`.DS_Store`, `.idea/`, `.vscode/`, `*.swp`). Don't reorder or rewrite existing lines.
- If none exists, generate one fitting the stack. Always cover: dependency dirs (`node_modules/`, `.venv/`, `target/`, `vendor/`, …), build output (`.next/`, `dist/`, `build/`, `out/`), env files (`.env*`), logs, and OS/editor cruft. A good source is GitHub's templates at https://github.com/github/gitignore — adapt, don't blindly dump.

### 3. `CLAUDE.md`
If absent, generate a concise (<30 lines) project `CLAUDE.md` from real inspection:
- **Stack** line (frameworks + language + package manager).
- **Commands** — build / test / run / lint, read from the manifest (`package.json` scripts, `Makefile`, `pyproject.toml`, etc.). Don't invent commands that aren't defined.
- **Entry points** — the actual main/index/layout files.
- **Structure** — one line per top-level source dir, describing its role.
- **Conventions / non-obvious notes** — path aliases, generated dirs, gotchas you observed.
- **Coding guidelines** — priority order when they conflict (earlier wins): 1) follow the detected tech stack's own conventions and idioms before personal preference; 2) readability for humans — structure and naming a human reads effortlessly (intent-revealing names, obvious control flow, small focused units); 3) simplicity — the least code that solves the problem, no speculative abstraction.
- **Documentation** — every change updates the docs it affects in the same change (`README.md` and any relevant files under `docs/`); stack, command, structure, or workflow changes must be reflected before the change is done.
- **Git workflow** — include the rule: when pushing to `origin`, pull with rebase first, then push (`git pull --rebase origin <branch>` before `git push`).

If a `CLAUDE.md` already exists, leave it; offer to extend it only if the user asks.

### 4. Standard files (add only if missing)
- `.editorconfig` — UTF-8, LF, sensible indent for the stack, trim trailing whitespace, final newline.
- Runtime version pin — `.nvmrc` (Node), `.python-version` (Python), `.tool-versions` (asdf/mise), etc., matching the installed/declared version.
- `README.md` — only if none exists: what it is, how to install, run, test. Keep it short.
- Ask before adding anything non-obvious (LICENSE, `.env.example`, CI config, PR templates) — these depend on intent.

### 5. Claude Code hooks (`.claude/settings.json`)
Set up hooks that enforce project hygiene automatically. **Idempotent + surgical:** if a settings file already exists, parse it and merge into the existing `hooks` arrays (append entries that aren't already present) — never overwrite a user's existing config.

**Verified hook mechanics** (Claude Code ≥ v2.1.141 for `terminalSequence`):
- `matcher` matches **tool names only** (`"Write|Edit"`, `"Bash"`, `mcp__.*`). For argument-level filtering, add a separate `"if"` field using permission-rule syntax — e.g. `"if": "Bash(rm *)"`, `"if": "Edit(*.ts)"`. Don't try to put argument patterns in `matcher`.
- A hook script reads the event JSON on **stdin** (`tool_name`, `tool_input.file_path`, `tool_input.command`, …) and emits a JSON decision on **stdout**:
  - **Hard block** — `PreToolUse`: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"…"}}` (values: `deny`/`allow`/`ask`/`defer`). Exit code 2 also blocks. This is the only true hard stop, not a nudge.
  - **Feed context back** — `PostToolUse`/`Stop`/`SessionStart`: `{"hookSpecificOutput":{"hookEventName":"…","additionalContext":"…"}}`.
  - **Force continuation** — `Stop`: `{"decision":"block","reason":"…"}` keeps Claude working.
  - **Notify** — `{"terminalSequence":"<OSC sequence>"}` (e.g. OSC `777;notify`); falls back to `osascript`/`curl` below.

**Where to write them** — ask the user: *"Is this project meant for agentic / unattended development?"*
- **Yes → split.** Team-shared, deterministic hooks (auto-format, destructive-command guard, sensitive-path guard, test-on-edit, Stop gate) → committed `.claude/settings.json`. Personal/machine-specific (notification webhook or Slack URL, SessionStart git state) → `.claude/settings.local.json`.
- **No / personal only → all local.** Everything in `.claude/settings.local.json`.

Either way, ensure `.claude/settings.local.json` is in `.gitignore` (add it if missing) so personal config and any webhook URLs never get committed. Keep any non-trivial hook body in a script under `.claude/hooks/` and reference it by path; only inline true one-liners.

**Tier A — add automatically (zero-config, low-risk):**
1. **Auto-format** — `PostToolUse` matcher `Write|Edit` → run the detected formatter on `tool_input.file_path` (table below). Eliminates nitpick formatting diffs.
2. **Block destructive commands** — `PreToolUse` matcher `Bash` → script inspects `tool_input.command` and returns `permissionDecision:"deny"` for `rm -rf`, `git push --force`(`-f`) to shared branches, `git reset --hard` on a dirty tree, `git clean -fdx`, etc.
3. **Protect sensitive paths** — `PreToolUse` matcher `Edit|Write|Bash` → deny when `tool_input.file_path` / `tool_input.command` touches `.env*`, credential/key files, lockfiles, applied migrations, or `node_modules/`.

**Tier B — present as an opt-in checklist, add only the ones the user confirms** (behavior-changing or needing project-specific values):
4. **Test-on-edit** — `PostToolUse` matcher `Write|Edit` on source files → map source path → test path, run that test, return failures as `additionalContext` so Claude self-corrects. Needs the project's source→test mapping; skip if it can't be derived.
5. **Stop test/build gate** — `Stop` → run the full test/build command; on failure return `{"decision":"block","reason":"<failures>"}`. Highest-leverage for unattended/agentic runs — stops Claude declaring victory on broken code.
6. **SessionStart state** — `SessionStart` → inject current git branch, uncommitted files, and any open-issue context as `additionalContext`. Only for state that changes between sessions; static conventions belong in `CLAUDE.md`, not a hook.
7. **Notify on completion** — `Notification`/`Stop` → desktop/Slack ping via `terminalSequence` (preferred), else `osascript -e 'display notification'` (macOS) or `curl` to a webhook (URL from env / `settings.local.json`, never hard-coded).

Formatter by stack (Tier A #1): Node/JS-TS → `prettier --write` (or `biome format --write`); Python → `black` / `ruff format`; Go → `gofmt -w` / `goimports`; Rust → `rustfmt`; Java/Kotlin → `google-java-format` / `ktlint -F`; Ruby → `rubocop -A`; PHP → `php-cs-fixer`. Only wire a formatter that's actually available in the project (declared dep or on PATH); otherwise note it and skip.

### 6. Initialize git + first commit
- If already a git repo, skip init; otherwise `git init -b main`.
- `git add -A`, then verify nothing unwanted is staged:
  `git ls-files | grep -E 'node_modules|\.venv|/dist/|/build/|\.next/|\.DS_Store|\.env|settings\.local\.json'` should be empty. If not, fix `.gitignore` / `git rm --cached` before committing.
- Commit **only if something is staged** (`git diff --cached --quiet || git commit -m "<message>"`) so a re-run on an already-committed clean tree skips instead of erroring on "nothing to commit": `Initial commit: <one-line project description>` (or, for an existing repo, a fitting message for just the added files).

### 7. Create the private GitHub repo and push
- Ensure `gh` is installed: `gh --version`. If missing, offer `brew install gh` (macOS) or the platform equivalent.
- Ensure authenticated: `gh auth status`. If a `GITHUB_TOKEN`/auth with `repo` scope is already present, that's enough — no interactive login needed. Otherwise have the user run `gh auth login` themselves via the `!` prefix (it's interactive).
- Confirm repo name (default = folder name) and visibility (default = private) with the user, then **create or reuse** the remote so a resume after a partial run converges instead of erroring on "already exists":
  - If `gh repo view <owner>/<name>` shows it already exists, don't re-create it — ensure `origin` points at it (`git remote get-url origin || git remote add origin <url>`) and `git push -u origin main`.
  - Otherwise `gh repo create <name> --private --source=. --remote=origin --push`.

### 8. Verify and report
- `git status` → clean tree on `main`.
- `git log --oneline` → the initial commit present.
- `git remote -v` and `gh repo view <owner>/<name>` → repo exists, correct visibility, `main` pushed.
- Report the repo URL.

## Notes
- On macOS the user's git is typically pre-configured; if `git config user.email` is empty, ask before committing.
- For org repos, the token may need `read:org`; a personal repo only needs `repo` scope.
