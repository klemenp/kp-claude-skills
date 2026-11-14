import json
import os
import re
import subprocess
import sys

LIB = os.environ["KP_GH_LIB_BIN"]
REPO = re.compile(r"[^/\s]+/[^/\s]+")
SHA = re.compile(r"[0-9a-f]{7,40}")
NEEDS_CONTRACT = "needs-contract"
IN_FLIGHT = {"In progress", "In review"}
VALUED = {"--repo", "--project-id", "--sha"}


def usage(problem):
    print(f"backfill-candidates.sh: {problem}", file=sys.stderr)
    print("usage: backfill-candidates.sh --repo <owner/repo> --project-id <id> "
          "--sha <synced SHA> [--labelled]", file=sys.stderr)
    sys.exit(2)


def parse(argv):
    options = {"--labelled": False}
    index = 0
    while index < len(argv):
        flag = argv[index]
        if flag == "--labelled":
            options[flag] = True
            index += 1
            continue
        if flag not in VALUED:
            usage(f"unknown argument {flag}")
        if index + 1 >= len(argv):
            usage(f"{flag} needs a value")
        options[flag] = argv[index + 1]
        index += 2
    for flag in sorted(VALUED):
        if not options.get(flag):
            usage(f"missing {flag}")
    if not REPO.fullmatch(options["--repo"]):
        usage(f"--repo {options['--repo']} is not <owner>/<name>")
    if not SHA.fullmatch(options["--sha"]):
        usage(f"--sha {options['--sha']} is not 7-40 lowercase hex")
    return options


def run(*command):
    """stdout of the command; on failure its stderr goes to ours and the script exits 1."""
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stderr or f"{command[0]} exited {result.returncode}\n")
        sys.exit(1)
    return result.stdout


def paginated(text):
    """`gh api --paginate` prints one JSON array per page, back to back."""
    decoder = json.JSONDecoder()
    entries, position = [], 0
    text = text.strip()
    while position < len(text):
        page, position = decoder.raw_decode(text, position)
        entries.extend(page)
        while position < len(text) and text[position].isspace():
            position += 1
    return entries


def failed_at_sha(repo, number, sha):
    marker = f"<!-- kp-sync-spec-tasks:backfill-failed {sha} -->"
    comments = paginated(run("gh", "api", "--paginate", f"repos/{repo}/issues/{number}/comments"))
    return any(line.strip() == marker
               for comment in comments
               for line in (comment.get("body") or "").splitlines())


def status_of(repo, number, project_id):
    looked_up = json.loads(run(os.path.join(LIB, "item-id.sh"), repo, str(number), project_id))
    return looked_up.get("status")


def main():
    options = parse(sys.argv[1:])
    repo, project_id, sha = options["--repo"], options["--project-id"], options["--sha"]
    labelled = options["--labelled"]
    if labelled:
        listing = ("gh", "issue", "list", "-R", repo, "--label", NEEDS_CONTRACT, "--state", "open",
                   "--limit", "1000", "--json", "number,title,body,labels")
    else:
        listing = ("gh", "issue", "list", "-R", repo, "--state", "open", "--label", "type:coding",
                   "--limit", "1000", "--json", "number,title,body,labels")
    candidates = []
    for issue in sorted(json.loads(run(*listing)), key=lambda issue: issue["number"]):
        labels = [label["name"] for label in issue.get("labels") or []]
        failed = NEEDS_CONTRACT in labels and failed_at_sha(repo, issue["number"], sha)
        skip, status = None, None
        if failed and not labelled:
            skip = "unchanged-failure"
        else:
            status = status_of(repo, issue["number"], project_id)
            if status in IN_FLIGHT:
                skip = "in-progress"
        candidates.append({"number": issue["number"], "title": issue["title"],
                           "body": issue["body"], "labels": labels, "status": status,
                           "failedAtSha": failed, "skip": skip})
    print(json.dumps(candidates))


main()
