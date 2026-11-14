---
name: kp-bootstrap-python-microservice
description: Scaffold a production-grade Python FastAPI microservice skeleton (FastAPI + Uvicorn, Pydantic v2, pytest, ruff, mypy strict) with pinned requirements and a verified initial commit. Use this skill whenever the user asks to bootstrap, scaffold, or start a new Python web service, microservice, FastAPI project, API skeleton, or backend service in Python — even if they don't explicitly name "FastAPI" or "microservice". Defaults to Python 3.12 but accepts any MAJOR.MINOR version the user names (3.11, 3.13, etc.).
model: sonnet
---

# Bootstrap Python Microservice

Scaffold a production-shape Python FastAPI microservice. The skeleton is intentionally empty of business logic — it sets up the layered structure (api / services / repositories / cache / domain / core), tooling (ruff, mypy strict, pytest, coverage), pinned dependencies, and a verified `/health` boot — and stops there. Later sessions add the real endpoints.

## When to use

Trigger whenever the user is starting a fresh Python service and any of these are true:

- They say "bootstrap", "scaffold", "start", or "new project" alongside Python / FastAPI / microservice / API / service / backend.
- They mention a Python version explicitly (e.g. "set up a Python 3.13 service").
- They describe the stack we produce (FastAPI + Uvicorn + Pydantic + pytest + ruff + mypy) without naming the skill.
- They give a directory and ask you to "set it up".

Don't trigger when the user wants to *add to* an existing project, change one file, or build a non-FastAPI Python service (e.g. a CLI, a data pipeline, a Django app). This skill is opinionated and won't fit those.

## What the skill produces

A directory tree shaped exactly like this — no business logic, just the structural seams future code will plug into:

```
<project>/
├── app/
│   ├── __init__.py
│   ├── main.py                  # create_app() factory; only /health wired up
│   ├── config.py                # Settings(BaseSettings) with all keys + defaults
│   ├── api/
│   │   ├── __init__.py
│   │   ├── deps.py              # empty placeholder
│   │   └── routes/
│   │       ├── __init__.py
│   │       └── health.py        # GET /health → {"status":"ok"}
│   ├── core/
│   │   ├── __init__.py
│   │   ├── logging.py           # configure_logging() — JSON stdout logs
│   │   └── exceptions.py        # AppError + NotFoundError/ConflictError/AuthError
│   ├── domain/__init__.py
│   ├── services/__init__.py
│   ├── repositories/__init__.py
│   └── cache/__init__.py
├── tests/
│   ├── __init__.py
│   ├── conftest.py              # empty placeholder
│   ├── unit/__init__.py
│   └── integration/__init__.py
├── data/.gitkeep
├── .env.example                 # all settings keys documented
├── .gitignore                   # Python + caches + venv + .env + data/*.json (keep .gitkeep)
├── .dockerignore
├── pyproject.toml               # PEP 621; ruff/mypy strict/pytest/coverage all configured
├── requirements.txt             # pinned runtime deps
├── requirements-dev.txt         # pinned dev deps (-r requirements.txt + dev-only)
└── README.md                    # one-line placeholder
```

`Settings` keys: `app_name, env, host, port, data_file, basic_auth_user, basic_auth_password, cache_ttl_seconds, cache_max_size, log_level`.

## How to run it

The skill is implemented as a single Python script. Run it with the variables the user gave (or defaults).

```bash
python3 ~/.claude/skills/kp-bootstrap-python-microservice/scripts/bootstrap.py \
  --target-dir <path> \
  --project-name <name> \
  --python-version <X.Y>
```

Defaults: `--project-name my-service`, `--python-version 3.12`. `--target-dir` is required.

### Inferring the variables

- **`--target-dir`** — Use the current working directory if the user is already inside the intended project dir. If they named a directory ("set up the service in `~/code/foo`"), use that. If they want a new dir created, create it as the target.
- **`--project-name`** — Use the name the user gave. If they didn't, derive from `target-dir.name`. Must match `^[a-z][a-z0-9_-]*$`; if it doesn't, ask before slugifying.
- **`--python-version`** — Use what the user said ("Python 3.13" → `3.13`). If unspecified, default to `3.12`. Must be `MAJOR.MINOR`. The interpreter (`pythonX.Y`) must actually exist on PATH — the script verifies this and fails loudly if not, so you don't have to.

### Optional flags

- `--force` — Overwrite a non-empty target. Use only when the user explicitly asks.
- `--skip-verify` — Skip ruff/mypy/pytest/uvicorn checks. Don't use this casually; verification is the whole point of the skill catching skeleton-level mistakes.
- `--skip-git` — Skip the initial commit. Useful only if the user wants to inspect first or already has a git history they're appending to.

## What the script does, in order

1. **Validates** `python_version` format and locates a matching interpreter on PATH.
2. **Scaffolds** the directory tree, copying templates from `templates/` with `{{PROJECT_NAME}}`, `{{PYTHON_VERSION}}`, `{{PYTHON_VERSION_NODOT}}` (e.g. `312` for ruff `target-version`), and `{{PYTHON_NEXT_MAJOR}}` (for `requires-python` upper bound) substituted in.
3. **Creates** `.venv` with the requested interpreter and runs `pip install -e ".[dev]"`.
4. **Pins requirements**:
   - If `pip-tools` is installed in the venv, runs `pip-compile` for both runtime and dev extras.
   - Otherwise hand-pins from `pip freeze`. To split runtime vs dev, the script spins up a *probe* venv with only `pip install -e .` (no extras) and treats packages present there as runtime, everything else as dev. Each file gets a header comment noting how to regenerate.
5. **Verifies** the skeleton:
   - `ruff check .` and `ruff format --check .`
   - `mypy app` (strict)
   - `pytest` — exit code `5` (no tests collected) is treated as success for a skeleton, not failure.
   - Boots `uvicorn app.main:create_app --factory` on a free port and polls `GET /health` in a loop until it returns 200 with `{"status":"ok"}`. **Never use a fixed sleep** — uvicorn logs "running" before the socket is fully bound, and a `sleep 2` followed by curl race-loses about 1 time in 5. The poll loop is in the script; don't try to write one around it.
6. **Initializes git** with `git init -b main` and creates the commit `chore: bootstrap project skeleton`.

## After the script returns

Briefly tell the user:
- where the project lives,
- the exact `uvicorn` command to re-launch it locally (`source .venv/bin/activate && uvicorn app.main:create_app --factory`),
- and which checks passed (ruff / mypy / pytest / `/health`).

Do **not**:

- Add real endpoints, schemas, services, or repository implementations. The skill produces a skeleton on purpose so later sessions can layer on business logic with full context.
- Replace the JSON logger with a fancier one, add middleware, or wire CORS/auth. Those are project decisions, not skeleton decisions.
- Move past the initial commit (no second commit, no PR, no push).

If the user asks for any of the above immediately after bootstrap, treat that as a separate task and ask whether they want it as a follow-up.

## Edge cases & failure modes

- **Interpreter not found.** The script fails with a clear message. Recommend `pyenv install <version>` or downloading from python.org — do not silently fall back to a different version, because `requires-python` and the ruff/mypy `target-version` are pinned to what the user asked for.
- **`pip-tools` not installed.** Expected and handled — script hand-pins. Don't try to install pip-tools just to "do it properly"; the hand-pin path is the documented fallback.
- **`pytest` exits 5.** That's "no tests collected" and is *success* for a skeleton. The script handles this; don't second-guess it.
- **`/health` returns the wrong body or never starts.** The script kills uvicorn and exits non-zero with the captured error. If this happens, read `app/main.py` and the uvicorn output — almost always an import error in the templated code, not a real runtime bug.
- **Target dir is non-empty.** The script refuses without `--force`. Re-running on the same dir after a partial bootstrap is allowed if only `.git` and/or `.venv` are present.

## Files in this skill

- `SKILL.md` — this file.
- `scripts/bootstrap.py` — the script that does the work. Single-file, stdlib-only (uses `urllib`, `subprocess`, `socket`); no extra dependencies for the skill itself.
- `templates/` — every file the skeleton emits, with `{{PROJECT_NAME}}` / `{{PYTHON_VERSION}}` placeholders where appropriate. `.tmpl` suffix marks files renamed on copy (e.g. `gitignore.tmpl` → `.gitignore`). Files under `templates/app/` and `templates/tests/` keep their final names — they're copied verbatim with placeholder substitution.
