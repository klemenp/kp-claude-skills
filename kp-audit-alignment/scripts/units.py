#!/usr/bin/env python3
"""Split a trace-matrix.sh output into kp-audit-alignment's units (its step 2).

Usage: units.py <matrix.json> --clone <owner/repo>=<path> ... [--contract REQ-<AREA>-<nnn>]

One unit per REQ area per owning repo. A unit's items are the covered items of its REQs
(only that REQ's with --contract); its paths are the files those items' merged PRs changed
plus their `code:` paths (a directory expands to the files under it), as they exist at the
repo's `shas` commit, read from the clone's `origin` tree at that commit. Each `untraced`
path joins the unit of the same repo whose paths share its longest directory prefix (a tie
goes to the first unit by area); a path sharing no directory with any unit is not audited.
The matrix's `noSpecRef` items are not audited either.

Prints one JSON object:
  {"units": [{"area", "repo", "sha", "cacheKey", "pathsHash", "reqs", "uncovered", "items",
              "paths", "untraced"}],
   "notAudited": {"paths": {"owner/repo": [...]}, "items": ["owner/repo#n", ...]}}
`cacheKey` names the unit's cache file: the area, `<AREA>-M<n>` for a milestone unit, the
REQ id for a contract unit — a unit holding fewer items must not reuse a wider unit's
description. `pathsHash` is the sha256 of the unit's sorted paths and untraced paths: the
cache is valid only for the path list it was built from, so a new `code:` line or untraced
paths joining differently (an --area run joins more than an --all run) make it stale.

Exit: 0 ok · 1 a git read failed · 2 bad arguments (an unknown --contract id included).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import posixpath
import re
import subprocess
import sys

GIT_TIMEOUT_SECONDS = 60
REQ_ID = re.compile(r"REQ-([A-Z]+)-\d{3}")


def fail(message: str, code: int) -> None:
    print(f"units.py: {message}", file=sys.stderr)
    sys.exit(code)


def tree_files(clone: str, sha: str) -> set[str]:
    command = ["git", "-C", clone, "ls-tree", "-r", "--name-only", sha]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=GIT_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        fail(f"{' '.join(command)} timed out after {GIT_TIMEOUT_SECONDS}s", 1)
    if result.returncode != 0:
        fail(f"{' '.join(command)} failed: {result.stderr.strip()}", 1)
    return set(result.stdout.splitlines())


def code_files(code_path: str, tree: set[str]) -> set[str]:
    path = code_path.strip("/")
    if path in tree:
        return {path}
    return {file for file in tree if file.startswith(path + "/")}


def shared_directories(path: str, other: str) -> int:
    """How many leading directory components the two paths' directories share."""
    count = 0
    for mine, theirs in zip(posixpath.dirname(path).split("/"), posixpath.dirname(other).split("/")):
        if not mine or mine != theirs:
            break
        count += 1
    return count


def build_units(matrix: dict, clones: dict[str, str], contract: str | None) -> dict:
    scope = matrix["scope"]
    covered, uncovered = matrix["covered"], matrix["uncovered"]
    if contract:
        if contract not in covered and contract not in uncovered:
            fail(f"{contract} is not a requirement in this matrix", 2)
        covered = {contract: covered[contract]} if contract in covered else {}
        uncovered = [contract] if contract in uncovered else []

    grouped: dict[tuple[str, str], dict] = {}

    def unit_for(req: str, repo: str) -> dict:
        area = REQ_ID.fullmatch(req).group(1)
        return grouped.setdefault((area, repo), {
            "area": area, "repo": repo, "reqs": [], "uncovered": [], "items": {}})

    for req, entry in covered.items():
        unit = unit_for(req, entry["repo"])
        unit["reqs"].append(req)
        for record in entry["items"]:
            unit["items"][record["item"]] = record
    for req in uncovered:
        area = REQ_ID.fullmatch(req).group(1)
        unit = unit_for(req, matrix["areas"][area])
        unit["reqs"].append(req)
        unit["uncovered"].append(req)

    trees = {}
    for repo in {repo for _, repo in grouped}:
        if repo not in clones:
            fail(f"no --clone for {repo}", 2)
        trees[repo] = tree_files(clones[repo], matrix["shas"][repo])

    units = []
    for (area, repo), unit in sorted(grouped.items()):
        tree = trees[repo]
        paths = set()
        for record in unit["items"].values():
            paths.update(file for file in record["files"] if file in tree)
            for code_path in record["code"]:
                paths.update(code_files(code_path, tree))
        if contract:
            cache_key = contract
        elif scope["kind"] == "milestone":
            cache_key = f"{area}-{scope['value']}"
        else:
            cache_key = area
        units.append({
            "area": area, "repo": repo, "sha": matrix["shas"][repo], "cacheKey": cache_key,
            "reqs": sorted(unit["reqs"]), "uncovered": sorted(unit["uncovered"]),
            "items": sorted(unit["items"]), "paths": sorted(paths), "untraced": []})

    not_audited: dict[str, list[str]] = {}
    for repo, paths in matrix["untraced"].items():
        candidates = [unit for unit in units if unit["repo"] == repo and unit["paths"]]
        for path in paths:
            best, best_shared = None, 0
            for unit in candidates:
                shared = max(shared_directories(path, other) for other in unit["paths"])
                if shared > best_shared:
                    best, best_shared = unit, shared
            if best is None:
                not_audited.setdefault(repo, []).append(path)
            else:
                best["untraced"].append(path)

    for unit in units:
        path_list = "\n".join(unit["paths"]) + "\n--untraced--\n" + "\n".join(sorted(unit["untraced"]))
        unit["pathsHash"] = hashlib.sha256(path_list.encode()).hexdigest()

    return {"units": units,
            "notAudited": {"paths": not_audited, "items": matrix.get("noSpecRef", [])}}


def main() -> int:
    parser = argparse.ArgumentParser(prog="units.py")
    parser.add_argument("matrix")
    parser.add_argument("--clone", action="append", default=[], metavar="<owner/repo>=<path>")
    parser.add_argument("--contract")
    args = parser.parse_args()
    if args.contract and not REQ_ID.fullmatch(args.contract):
        fail(f"--contract takes a REQ-<AREA>-<nnn> id, not {args.contract}", 2)
    clones = {}
    for pair in args.clone:
        repo, separator, path = pair.partition("=")
        if not separator or not repo or not path:
            fail(f"--clone takes <owner/repo>=<path>, not {pair}", 2)
        clones[repo] = path
    with open(args.matrix, encoding="utf-8") as handle:
        matrix = json.load(handle)
    print(json.dumps(build_units(matrix, clones, args.contract), indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
