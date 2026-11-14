import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

spec_index_script, checkout, spec_repo, target_arg, scope_kind, scope_value, ref = sys.argv[1:]

GH_TIMEOUT_SECONDS = 30
# A paginated call is many requests under one process.
GH_PAGINATED_TIMEOUT_SECONDS = 300
HUMAN_ONLY_FENCE = re.compile(
    r"<!--\s*human-only:start.*?(?:<!--\s*human-only:end\s*-->|\Z)", re.S)
SPEC_REF_LINE = re.compile(r"^[ \t]*spec-ref:(.*)$", re.M)
SERVES_LINE = re.compile(r"^[ \t]*serves:(.*)$", re.M)
CODE_LINE = re.compile(r"^[ \t]*code:[ \t]*([^\s#]+)", re.M)
MILESTONE_REF = re.compile(r"^[ \t]*spec-ref:[ \t]*milestone:(M\d+)[ \t]*$", re.M)
REQ_ID = re.compile(r"\bREQ-([A-Z]+)-\d{3}\b")
GOAL = re.compile(r"\bG-\d+\b")
# GitHub's closing keywords, as a PR body uses them to link the issues it closes.
CLOSING_REF = re.compile(
    r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b:?[ \t]+([\w.-]+/[\w.-]+)?#(\d+)\b", re.I)
REMOTE = re.compile(r"(?:github\.com[:/])([^/]+/[^/]+?)(?:\.git)?/?$")
REPO_NAME = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
TRACE_CACHE_DIR = pathlib.Path(spec_index_script).parent.parent / "state" / "trace-cache"
TRACE_CACHE_VERSION = 1


def fail(message, code=1):
    print(f"trace-matrix.sh: {message}", file=sys.stderr)
    sys.exit(code)


def gh_json(endpoint, paginate=False, missing_ok=False):
    """missing_ok: a 404 (absent, transferred or inaccessible) returns None, not a failure."""
    command = ["gh", "api", "-X", "GET", endpoint]
    if paginate:
        command += ["--paginate", "--slurp"]
    timeout = GH_PAGINATED_TIMEOUT_SECONDS if paginate else GH_TIMEOUT_SECONDS
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        fail(f"gh api {endpoint} timed out after {timeout}s")
    if result.returncode != 0:
        if missing_ok and "HTTP 404" in result.stderr:
            return None
        fail(f"gh api {endpoint} failed: {result.stderr.strip()}")
    data = json.loads(result.stdout)
    if paginate:
        return [entry for page in data for entry in page]
    return data


def search_issues(query):
    try:
        result = subprocess.run(
            ["gh", "api", "-X", "GET", "search/issues", "--paginate", "--slurp",
             "-f", f"q={query}", "-f", "per_page=100"],
            capture_output=True, text=True, timeout=GH_PAGINATED_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        fail(f"issue search timed out after {GH_PAGINATED_TIMEOUT_SECONDS}s: {query}")
    if result.returncode != 0:
        fail(f"issue search failed ({query}): {result.stderr.strip()}")
    return [item for page in json.loads(result.stdout) for item in page["items"]]


def outside_fence(body):
    return HUMAN_ONLY_FENCE.sub("", (body or "").replace("\r\n", "\n"))


def repo_of(issue):
    return "/".join(issue["repository_url"].split("/")[-2:])


def label_names(issue):
    return {label["name"] for label in issue["labels"]}


# --- config and routing ---------------------------------------------------------------

origin = subprocess.run(["git", "-C", checkout, "remote", "get-url", "origin"],
                        capture_output=True, text=True).stdout.strip()
match = REMOTE.search(origin)
if not match or match.group(1).lower() != spec_repo.lower():
    fail(f"{checkout} is not a checkout of {spec_repo} (origin: {origin or 'none'})", 2)

config_path = pathlib.Path(checkout) / ".claude" / "spec-sync.json"
config = json.loads(config_path.read_text()) if config_path.exists() else {}
target_repo = target_arg or config.get("targetRepo")
# Some configs wrap the value: {"targetRepo": {"value": "<owner/repo>"}}.
if isinstance(target_repo, dict):
    target_repo = target_repo.get("value")
if not target_repo:
    fail(f"no target repo: pass --repo <target-repo> or set targetRepo in {config_path}", 2)

area_repos = {area: entry["repo"] for area, entry in config.get("requirementRepos", {}).items()
              if isinstance(entry, dict) and entry.get("repo")}
routed = []
for repo in [target_repo, *area_repos.values()]:
    # A routed repo names its trace-cache file, so it must be a safe owner/repo pair.
    if (not isinstance(repo, str) or not REPO_NAME.fullmatch(repo)
            or any(segment in (".", "..") for segment in repo.split("/"))):
        fail(f"invalid repo {repo!r} in --repo or {config_path}", 2)
    if repo.lower() not in (known.lower() for known in routed):
        routed.append(repo)
canonical = {repo.lower(): repo for repo in routed}


def owning_repo(area):
    return area_repos.get(area, target_repo)


def trace_cache_file(repo):
    owner, name = repo.lower().split("/")
    return TRACE_CACHE_DIR / owner / f"{name}.json"


def load_trace_cache(repo):
    """A merged PR's cached filenames by PR number; a missing or malformed file is empty."""
    path = trace_cache_file(repo)
    try:
        cache = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        print(f"trace-matrix.sh: no trace cache at {path}, starting empty", file=sys.stderr)
        return {}
    except (OSError, ValueError) as error:
        print(f"trace-matrix.sh: unreadable trace cache {path} ({error}), starting empty",
              file=sys.stderr)
        return {}
    if (not isinstance(cache, dict) or cache.get("version") != TRACE_CACHE_VERSION
            or not isinstance(cache.get("prs"), dict)):
        print(f"trace-matrix.sh: trace cache {path} is not version {TRACE_CACHE_VERSION}, "
              "starting empty", file=sys.stderr)
        return {}
    return cache["prs"]


def save_trace_cache(repo, prs):
    path = trace_cache_file(repo)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent,
                                         delete=False) as handle:
            json.dump({"version": TRACE_CACHE_VERSION, "prs": prs}, handle)
        os.replace(handle.name, path)
    except OSError as error:
        print(f"trace-matrix.sh: could not write trace cache {path}: {error}", file=sys.stderr)


def default_branch_sha(repo):
    branch = gh_json(f"repos/{repo}")["default_branch"]
    return branch, gh_json(f"repos/{repo}/commits/{branch}")["sha"]


def read_ref_sha(repo):
    """The branch read for a code repo and its SHA: the --ref when it exists, else default."""
    if ref:
        found = gh_json(f"repos/{repo}/branches/{ref}", missing_ok=True)
        if found is not None:
            return ref, found["commit"]["sha"]
    return default_branch_sha(repo)


# --- the spec's requirements ----------------------------------------------------------

spec_sha = default_branch_sha(spec_repo)[1]
index = subprocess.run([spec_index_script, f"{spec_repo}@{spec_sha}"],
                       capture_output=True, text=True, timeout=GH_PAGINATED_TIMEOUT_SECONDS)
if index.returncode != 0:
    fail(f"spec-index.py failed: {index.stderr.strip()}")
requirements = {section["anchor"]: section.get("serves") or []
                for spec_file in json.loads(index.stdout)["files"].values()
                for section in spec_file["sections"] if section["kind"] == "req"}


def area_of(req):
    return REQ_ID.match(req).group(1)


# --- issues and merged PRs in the routed repos ----------------------------------------

issues = {}
for repo in routed:
    for issue in gh_json(f"repos/{repo}/issues?state=all&per_page=100", paginate=True):
        if "pull_request" not in issue:
            issues[f"{repo}#{issue['number']}"] = issue


def issue(ref):
    repo, number = ref.split("#")
    ref = f"{canonical.get(repo.lower(), repo)}#{number}"
    if ref not in issues:
        # A closing ref to a missing issue (a typo, a transfer, a private repo) closes
        # nothing; one stale PR body must not fail the whole trace.
        fetched = gh_json(f"repos/{repo}/issues/{number}", missing_ok=True)
        issues[ref] = None if fetched is None or "pull_request" in fetched else fetched
    return ref, issues[ref]


def markers(body):
    text = outside_fence(body)
    reqs = sorted({req.group(0) for line in SPEC_REF_LINE.findall(text)
                   for req in REQ_ID.finditer(line)})
    goals = sorted({goal for line in SERVES_LINE.findall(text) for goal in GOAL.findall(line)})
    return reqs, goals, sorted(set(CODE_LINE.findall(text)))


trees, shas, refs, merged_prs = {}, {}, {}, {}
for repo in routed:
    refs[repo], shas[repo] = read_ref_sha(repo)
    tree = gh_json(f"repos/{repo}/git/trees/{shas[repo]}?recursive=1")
    if tree.get("truncated"):
        fail(f"the tree of {repo}@{shas[repo]} is truncated")
    trees[repo] = {entry["path"] for entry in tree["tree"] if entry["type"] == "blob"}
    cached_files = load_trace_cache(repo)
    for pull in gh_json(f"repos/{repo}/pulls?state=closed&per_page=100", paginate=True):
        if not pull.get("merged_at"):
            continue
        if ((pull.get("head") or {}).get("ref") or "").startswith("release/"):
            continue
        number = str(pull["number"])
        entry = cached_files.get(number)
        if not (isinstance(entry, list) and all(isinstance(name, str) for name in entry)):
            entry = sorted({changed["filename"] for changed in
                            gh_json(f"repos/{repo}/pulls/{number}/files?per_page=100",
                                    paginate=True)})
            cached_files[number] = entry
        files = set(entry)
        closes = []
        for ref_repo, number in CLOSING_REF.findall(pull.get("body") or ""):
            closed_ref, closed = issue(f"{ref_repo or repo}#{number}")
            if closed is not None and closed_ref not in closes:
                closes.append(closed_ref)
        merged_prs[f"{repo}#{pull['number']}"] = {
            "repo": repo, "files": files & trees[repo], "closes": closes}
    save_trace_cache(repo, cached_files)

# item ref → merged PR refs that close it
prs_of = {}
for pr_ref, pull in merged_prs.items():
    for ref in pull["closes"]:
        prs_of.setdefault(ref, []).append(pr_ref)

# --- scope ----------------------------------------------------------------------------

epics, milestone_items = [], None
if scope_kind == "milestone":
    owners = sorted({repo.split("/")[0] for repo in routed})
    for owner in owners:
        owner_type = gh_json(f"users/{owner}")["type"]
        qualifier = "org" if owner_type == "Organization" else "user"
        for hit in search_issues(f'"spec-ref: milestone:{scope_value}" label:type:epic '
                                 f'is:issue {qualifier}:{owner}'):
            marker = MILESTONE_REF.search(outside_fence(hit["body"]))
            if (marker and marker.group(1) == scope_value and "type:epic" in label_names(hit)
                    and repo_of(hit).lower() in canonical):
                epics.append(f"{canonical[repo_of(hit).lower()]}#{hit['number']}")
    if not epics:
        fail(f"no milestone epic marked spec-ref: milestone:{scope_value} in {', '.join(routed)}")
    # Non-epic issues anywhere below the epics; a nested milestone epic is its own
    # milestone, so the walk does not enter it (as milestone-gate.sh walks).
    milestone_items, pending, seen = [], list(epics), set()
    while pending:
        parent = pending.pop()
        if parent in seen:
            continue
        seen.add(parent)
        parent_repo, parent_number = parent.split("#")
        for child in gh_json(f"repos/{parent_repo}/issues/{parent_number}/sub_issues?per_page=100",
                             paginate=True):
            child_ref = f"{canonical.get(repo_of(child).lower(), repo_of(child))}#{child['number']}"
            issues.setdefault(child_ref, child)
            if "type:epic" in label_names(child):
                if not MILESTONE_REF.search(outside_fence(child["body"])):
                    pending.append(child_ref)
            elif child_ref not in milestone_items:
                milestone_items.append(child_ref)

if scope_kind == "area":
    in_scope = sorted(req for req in requirements if area_of(req) == scope_value)
    if not in_scope:
        fail(f"no REQ-{scope_value}-* requirement in {spec_repo}@{spec_sha}", 2)
elif scope_kind == "milestone":
    in_scope = sorted({req for ref in milestone_items for req in markers(issues[ref]["body"])[0]
                       if req in requirements})
else:
    in_scope = sorted(requirements)

candidates = milestone_items if milestone_items is not None else sorted(prs_of)
covered = {}
for ref in candidates:
    if ref not in prs_of:
        continue
    reqs, goals, code = markers(issues[ref]["body"])
    files = sorted(set().union(*(merged_prs[pr]["files"] for pr in prs_of[ref])))
    record = {"item": ref, "title": issues[ref]["title"], "prs": sorted(prs_of[ref]),
              "serves": goals, "files": files, "code": code}
    for req in reqs:
        if req in in_scope:
            covered.setdefault(req, {"repo": owning_repo(area_of(req)),
                                     "serves": requirements[req], "items": []})
            covered[req]["items"].append(record)

scope_repos = sorted({owning_repo(area_of(req)) for req in in_scope}) if scope_kind != "all" \
    else routed

traced_files = {}
for pr_ref, pull in merged_prs.items():
    if any(req in requirements for ref in pull["closes"]
           for req in markers(issues[ref]["body"])[0]):
        traced_files.setdefault(pull["repo"], set()).update(pull["files"])
untraced = {}
for repo in scope_repos:
    changed = set().union(*(pull["files"] for pull in merged_prs.values() if pull["repo"] == repo))
    untraced[repo] = sorted(changed - traced_files.get(repo, set()))

no_serves = sorted({record["item"] for entry in covered.values() for record in entry["items"]
                    if not record["serves"]})
no_spec_ref = [] if milestone_items is None else sorted(
    ref for ref in milestone_items
    if not any(req in requirements for req in markers(issues[ref]["body"])[0]))

print(json.dumps({
    "spec": {"repo": spec_repo, "sha": spec_sha},
    "scope": {"kind": scope_kind, "value": scope_value or None, "epics": sorted(epics)},
    "covered": dict(sorted(covered.items())),
    "uncovered": [req for req in in_scope if req not in covered],
    "noServes": no_serves,
    "noSpecRef": no_spec_ref,
    "untraced": untraced,
    "areas": {area: owning_repo(area) for area in sorted({area_of(req) for req in in_scope})},
    "shas": {repo: shas[repo] for repo in scope_repos},
    "refs": refs,
}, indent=1))
