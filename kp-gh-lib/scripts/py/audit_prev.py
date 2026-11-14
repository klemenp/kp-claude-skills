import json
import os
import re
import subprocess
import sys
import tempfile

REPO = re.compile(r"[^/\s]+/[^/\s]+")
KEPT_PREFIXES = ("audit-shas:", "audit-filed:", "unfiled:", "refuted:", "|")
LIST_LIMIT = "200"


def usage(message):
    print(f"audit-prev.sh: {message}", file=sys.stderr)
    print("usage: audit-prev.sh <spec-repo> <unit> <run-dir>", file=sys.stderr)
    sys.exit(2)


def parse_args(argv):
    if len(argv) != 3:
        usage(f"expected 3 positional arguments, got {len(argv)}")
    spec_repo, unit, run_dir = argv
    if not REPO.fullmatch(spec_repo):
        usage(f"not an owner/repo: {spec_repo!r}")
    if not unit:
        usage("empty unit")
    if not os.path.isdir(run_dir):
        usage(f"run dir is not an existing directory: {run_dir!r}")
    return spec_repo, unit, run_dir


def closed_audits(spec_repo):
    command = ["gh", "issue", "list", "-R", spec_repo, "--label", "type:audit",
               "--state", "closed", "--limit", LIST_LIMIT, "--json", "number,body,closedAt"]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        sys.exit(1)
    return json.loads(result.stdout)


def previous_round(issues, unit):
    wanted = f"audit-unit: {unit}"
    matches = [issue for issue in issues
               if wanted in (issue.get("body") or "").replace("\r\n", "\n").split("\n")]
    return max(matches, key=lambda issue: issue["closedAt"], default=None)


def prev_spec_sha(lines, spec_repo):
    for line in lines:
        if not line.startswith("audit-shas:"):
            continue
        for entry in line[len("audit-shas:"):].split():
            repo, separator, sha = entry.partition("@")
            if separator and repo.lower() == spec_repo.lower():
                return sha
    return None


def write_atomically(run_dir, name, text):
    descriptor, temp_path = tempfile.mkstemp(dir=run_dir, prefix=f".{name}.")
    with os.fdopen(descriptor, "w") as handle:
        handle.write(text)
    os.replace(temp_path, os.path.join(run_dir, name))


spec_repo, unit, run_dir = parse_args(sys.argv[1:])
issue = previous_round(closed_audits(spec_repo), unit)
if issue is None:
    write_atomically(run_dir, "prev.json", "{}\n")
    write_atomically(run_dir, "prev-refuted.md", "")
    print("{}")
    sys.exit(0)

lines = [line for line in issue["body"].replace("\r\n", "\n").split("\n")
         if line.startswith(KEPT_PREFIXES)]
refuted = ([line for line in lines if line.startswith("audit-shas:")]
           + [line for line in lines if line.startswith("refuted:")])
prev = {"number": issue["number"], "closedAt": issue["closedAt"], "lines": lines}
write_atomically(run_dir, "prev.json", json.dumps(prev) + "\n")
write_atomically(run_dir, "prev-refuted.md", "".join(f"{line}\n" for line in refuted))
print(json.dumps({"number": issue["number"], "prevSpecSha": prev_spec_sha(lines, spec_repo)}))
