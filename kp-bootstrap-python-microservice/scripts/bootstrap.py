#!/usr/bin/env python3
"""Bootstrap a production-grade FastAPI microservice skeleton.

Usage:
    python bootstrap.py --target-dir PATH [--project-name NAME] [--python-version X.Y]

Designed to be idempotent on a fresh empty (or near-empty) target directory.
Refuses to overwrite an existing project unless --force is passed.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

SKILL_ROOT = Path(__file__).resolve().parent.parent
TEMPLATES = SKILL_ROOT / "templates"

# Directories that must exist (empty __init__.py created where needed).
EMPTY_INIT_DIRS = [
    "app",
    "app/api",
    "app/api/routes",
    "app/core",
    "app/domain",
    "app/services",
    "app/repositories",
    "app/cache",
    "tests",
    "tests/unit",
    "tests/integration",
]

# Templated files: (template_relative_path, destination_relative_path).
# A `.tmpl` suffix means the file goes through variable substitution.
TEMPLATE_FILES: list[tuple[str, str]] = [
    ("pyproject.toml.tmpl", "pyproject.toml"),
    ("env.example.tmpl", ".env.example"),
    ("gitignore.tmpl", ".gitignore"),
    ("dockerignore.tmpl", ".dockerignore"),
    ("README.md.tmpl", "README.md"),
    ("app/main.py", "app/main.py"),
    ("app/config.py", "app/config.py"),
    ("app/api/routes/health.py", "app/api/routes/health.py"),
    ("app/core/logging.py", "app/core/logging.py"),
    ("app/core/exceptions.py", "app/core/exceptions.py"),
]

EMPTY_FILES = [
    "app/api/deps.py",
    "tests/conftest.py",
    "data/.gitkeep",
]


def log(msg: str) -> None:
    print(f"[bootstrap] {msg}", flush=True)


def fail(msg: str) -> "None":
    print(f"[bootstrap] ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def render(text: str, variables: dict[str, str]) -> str:
    out = text
    for key, value in variables.items():
        out = out.replace("{{" + key + "}}", value)
    return out


def python_version_vars(version: str) -> dict[str, str]:
    m = re.match(r"^(\d+)\.(\d+)$", version)
    if not m:
        fail(f"--python-version must be MAJOR.MINOR (got {version!r})")
    major, minor = int(m.group(1)), int(m.group(2))  # type: ignore[union-attr]
    return {
        "PYTHON_VERSION": version,
        "PYTHON_VERSION_NODOT": f"{major}{minor}",
        "PYTHON_NEXT_MAJOR": f"{major}.{minor + 1}",
    }


def find_python_interpreter(version: str) -> str:
    """Locate the interpreter matching the requested MAJOR.MINOR."""
    candidates = [f"python{version}", "python3", "python"]
    for cmd in candidates:
        path = shutil.which(cmd)
        if not path:
            continue
        try:
            out = subprocess.check_output(
                [path, "-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"],
                text=True,
            ).strip()
        except subprocess.CalledProcessError:
            continue
        if out == version:
            return path
    fail(
        f"No Python {version} interpreter found on PATH. Tried: {', '.join(candidates)}. "
        f"Install it (e.g. via pyenv or python.org) or pick a version that's available."
    )
    return ""  # unreachable


def write_file(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)


def scaffold(target: Path, variables: dict[str, str], force: bool) -> None:
    if target.exists() and any(target.iterdir()) and not force:
        # Allow re-running if only .git or .venv is present from a half-bootstrap.
        ignorable = {".git", ".venv"}
        leftover = [p.name for p in target.iterdir() if p.name not in ignorable]
        if leftover:
            fail(
                f"Target {target} is not empty (contains: {', '.join(leftover)}). "
                f"Pass --force to overwrite."
            )
    target.mkdir(parents=True, exist_ok=True)

    for d in EMPTY_INIT_DIRS:
        (target / d).mkdir(parents=True, exist_ok=True)
        init = target / d / "__init__.py"
        if not init.exists():
            init.write_text("")

    for src_rel, dst_rel in TEMPLATE_FILES:
        src = TEMPLATES / src_rel
        if not src.exists():
            fail(f"Missing template: {src}")
        content = src.read_text()
        if src_rel.endswith(".tmpl") or "{{" in content:
            content = render(content, variables)
        write_file(target / dst_rel, content)

    for empty in EMPTY_FILES:
        p = target / empty
        p.parent.mkdir(parents=True, exist_ok=True)
        if not p.exists():
            p.write_text("")


def run(cmd: list[str], cwd: Path, check: bool = True, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    log(f"$ {' '.join(cmd)}")
    proc = subprocess.run(cmd, cwd=cwd, text=True, capture_output=True, env=env)
    if proc.stdout:
        print(proc.stdout, end="")
    if proc.stderr:
        print(proc.stderr, end="", file=sys.stderr)
    if check and proc.returncode != 0:
        fail(f"Command failed ({proc.returncode}): {' '.join(cmd)}")
    return proc


def create_venv(target: Path, interpreter: str) -> Path:
    venv = target / ".venv"
    if not venv.exists():
        run([interpreter, "-m", "venv", str(venv)], cwd=target)
    bin_dir = venv / ("Scripts" if os.name == "nt" else "bin")
    pip = bin_dir / "pip"
    run([str(pip), "install", "--upgrade", "pip", "--quiet"], cwd=target)
    run([str(pip), "install", "-e", ".[dev]"], cwd=target)
    return venv


def pin_requirements(target: Path, venv: Path, interpreter: str, project_name: str) -> None:
    """Generate requirements.txt + requirements-dev.txt.

    Use pip-compile if pip-tools is available in the venv; otherwise hand-pin
    from `pip freeze` and split runtime vs dev by inspecting which packages get
    installed by ``pip install <runtime>`` alone in a probe venv.

    ``interpreter`` is the same Python binary used for ``.venv``; the probe
    venv must also use it, since the project's ``requires-python`` is pinned
    and the script's own interpreter may not satisfy it.
    """
    bin_dir = venv / ("Scripts" if os.name == "nt" else "bin")
    pip = bin_dir / "pip"
    python = bin_dir / "python"

    have_pip_tools = subprocess.run(
        [str(python), "-c", "import piptools"],
        capture_output=True,
    ).returncode == 0

    if have_pip_tools:
        log("Using pip-compile to pin dependencies.")
        run(
            [str(bin_dir / "pip-compile"), "--quiet", "--output-file=requirements.txt", "pyproject.toml"],
            cwd=target,
        )
        run(
            [str(bin_dir / "pip-compile"), "--quiet", "--extra=dev", "--output-file=requirements-dev.txt", "pyproject.toml"],
            cwd=target,
        )
        return

    log("pip-tools not available; hand-pinning from resolved venv.")

    # Resolve a runtime-only probe venv to figure out which pins are runtime vs dev-only.
    probe = target / ".venv-probe"
    if probe.exists():
        shutil.rmtree(probe)
    run([interpreter, "-m", "venv", str(probe)], cwd=target)
    probe_pip = probe / ("Scripts" if os.name == "nt" else "bin") / "pip"
    run([str(probe_pip), "install", "--upgrade", "pip", "--quiet"], cwd=target)
    # Install only the runtime project (no extras).
    run([str(probe_pip), "install", "-e", "."], cwd=target)

    def freeze(pip_path: Path) -> dict[str, str]:
        proc = run([str(pip_path), "freeze", "--exclude-editable"], cwd=target, check=True)
        result: dict[str, str] = {}
        for line in proc.stdout.splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "@" in line:
                continue
            if "==" in line:
                name, ver = line.split("==", 1)
                result[name.strip().lower().replace("_", "-")] = f"{name}=={ver}"
        return result

    full = freeze(pip)
    runtime = freeze(probe_pip)
    shutil.rmtree(probe)

    runtime_lines = sorted(runtime[k] for k in runtime)
    dev_only_lines = sorted(full[k] for k in full if k not in runtime)

    header_runtime = (
        f"# Hand-pinned runtime dependencies for {project_name}.\n"
        f"# Regenerate by resolving against pyproject.toml "
        f"(e.g. pip-compile pyproject.toml).\n"
    )
    header_dev = (
        f"# Hand-pinned dev dependencies for {project_name} (includes runtime deps).\n"
        f"# Regenerate by resolving against pyproject.toml extras "
        f"(e.g. pip-compile --extra=dev pyproject.toml).\n"
        f"-r requirements.txt\n"
    )

    (target / "requirements.txt").write_text(header_runtime + "\n".join(runtime_lines) + "\n")
    (target / "requirements-dev.txt").write_text(header_dev + "\n".join(dev_only_lines) + "\n")


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_for_health(url: str, timeout_s: float = 15.0) -> tuple[int, str]:
    """Poll URL until HTTP 200 or timeout. No fixed sleeps — race-safe."""
    deadline = time.monotonic() + timeout_s
    last_err = ""
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=1.0) as resp:
                body = resp.read().decode()
                return resp.status, body
        except (urllib.error.URLError, ConnectionRefusedError, OSError) as e:
            last_err = str(e)
            time.sleep(0.2)
    return 0, last_err


def verify(target: Path, venv: Path) -> None:
    bin_dir = venv / ("Scripts" if os.name == "nt" else "bin")
    ruff = bin_dir / "ruff"
    mypy = bin_dir / "mypy"
    pytest = bin_dir / "pytest"
    uvicorn = bin_dir / "uvicorn"

    log("Running ruff check...")
    run([str(ruff), "check", "."], cwd=target)
    log("Running ruff format --check...")
    run([str(ruff), "format", "--check", "."], cwd=target)
    log("Running mypy app (strict)...")
    run([str(mypy), "app"], cwd=target)

    log("Running pytest (zero tests is acceptable; exit 5 is success here)...")
    proc = subprocess.run([str(pytest)], cwd=target, text=True, capture_output=True)
    print(proc.stdout, end="")
    print(proc.stderr, end="", file=sys.stderr)
    if proc.returncode not in (0, 5):
        fail(f"pytest failed with exit code {proc.returncode}")

    port = free_port()
    log(f"Booting uvicorn on 127.0.0.1:{port} for /health smoke test...")
    server = subprocess.Popen(
        [str(uvicorn), "app.main:create_app", "--factory", "--host", "127.0.0.1", "--port", str(port)],
        cwd=target,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    try:
        status, body = wait_for_health(f"http://127.0.0.1:{port}/health", timeout_s=15.0)
        if status != 200:
            tail = ""
            if server.stdout is not None:
                try:
                    server.stdout.close()
                except Exception:
                    pass
            fail(f"/health did not return 200 (got {status}); last error: {body[:200]}{tail}")
        if '"status":"ok"' not in body.replace(" ", ""):
            fail(f"/health body unexpected: {body!r}")
        log(f"/health → 200 {body}")
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()


def git_init_and_commit(target: Path) -> None:
    git_dir = target / ".git"
    if not git_dir.exists():
        run(["git", "init", "-b", "main"], cwd=target)
    # Stage everything tracked by .gitignore-aware add.
    run(["git", "add", "."], cwd=target)
    # Skip commit if nothing is staged (e.g. re-run with no changes).
    diff = subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=target)
    if diff.returncode == 0:
        log("Nothing to commit (working tree matches HEAD).")
        return
    run(["git", "commit", "-m", "chore: bootstrap project skeleton"], cwd=target)


def main() -> None:
    ap = argparse.ArgumentParser(description="Bootstrap a FastAPI microservice skeleton.")
    ap.add_argument("--target-dir", required=True, type=Path)
    ap.add_argument("--project-name", default="my-service")
    ap.add_argument("--python-version", default="3.12")
    ap.add_argument("--force", action="store_true", help="Overwrite existing files in target.")
    ap.add_argument("--skip-verify", action="store_true", help="Skip ruff/mypy/pytest/uvicorn checks.")
    ap.add_argument("--skip-git", action="store_true", help="Skip git init + commit.")
    args = ap.parse_args()

    if not re.match(r"^[a-z][a-z0-9_-]*$", args.project_name):
        fail(
            f"--project-name {args.project_name!r} must match ^[a-z][a-z0-9_-]*$ "
            f"(lowercase, may contain digits, hyphens, underscores)."
        )

    target = args.target_dir.expanduser().resolve()
    variables = {
        "PROJECT_NAME": args.project_name,
        **python_version_vars(args.python_version),
    }

    log(f"Target dir:      {target}")
    log(f"Project name:    {args.project_name}")
    log(f"Python version:  {args.python_version}")

    interpreter = find_python_interpreter(args.python_version)
    log(f"Interpreter:     {interpreter}")

    scaffold(target, variables, force=args.force)
    venv = create_venv(target, interpreter)
    pin_requirements(target, venv, interpreter, args.project_name)

    if not args.skip_verify:
        verify(target, venv)
    else:
        log("Skipping verification (--skip-verify).")

    if not args.skip_git:
        git_init_and_commit(target)
    else:
        log("Skipping git init/commit (--skip-git).")

    log("Done.")


if __name__ == "__main__":
    main()
