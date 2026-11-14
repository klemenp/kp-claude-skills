import hashlib
import json
import re
import subprocess
import sys

VERDICT_MARKER = "<!-- kp-review-gh-pr:verdict -->"
FIX_SUMMARY_MARKER = "<!-- kp-fix-pr:summary -->"
FINDINGS_HEADING = "### Findings (for the build agent)"
TLDR_HEADING = "### TL;DR (for humans)"

# Formal review states that decide a PR, mapped to the verdict-comment vocabulary.
FORMAL_VERDICTS = {"APPROVED": "APPROVED", "CHANGES_REQUESTED": "REQUEST_CHANGES"}

# A verdict is an approval only on an explicit `verdict: APPROVED` line; `kp-review-gh-pr`
# marks both outcomes with the same marker, so absence of the line is a denial.
APPROVED_VERDICT = re.compile(r"^verdict:\s*APPROVED\s*$", re.MULTILINE)
VERDICT_SHA = re.compile(r"^(?:approved|reviewed):\s*([0-9a-f]{7,40})\s*$", re.MULTILINE)
HUMAN_ONLY = re.compile(
    r"<!--\s*human-only:start.*?(?:<!--\s*human-only:end\s*-->|\Z)", re.DOTALL)
TOP_LEVEL_BULLET = re.compile(r"^- ")
BOLD_GROUP = re.compile(r"^\*\*(.+?)\*\*\s*$")

GH_TIMEOUT_SECONDS = 30

# Bold group headings, normalised to lowercase with whitespace removed.
SEVERITY_FIELDS = {
    "blockers": "blockers",
    "blocker": "blockers",
    "major": "major",
    "minor": "minor",
    "nits": "nits",
    "nit": "nits",
    "ci": "ci",
    "major/minor/nits": "combined",
}


def fail(message):
    print(f"pr-verdict-state.sh: {message}", file=sys.stderr)
    sys.exit(1)


def gh_json(args):
    """Run a `gh` read with a timeout; exit 1 on any failure, as the contract promises."""
    try:
        result = subprocess.run(["gh", *args], capture_output=True, text=True,
                                timeout=GH_TIMEOUT_SECONDS)
    except FileNotFoundError:
        fail("`gh` is not installed")
    except subprocess.TimeoutExpired:
        fail(f"`gh {' '.join(args)}` timed out after {GH_TIMEOUT_SECONDS}s")
    if result.returncode != 0:
        fail(f"`gh {' '.join(args)}` failed: {result.stderr.strip()}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        fail(f"`gh {' '.join(args)}` returned unparseable JSON: {error}")


def strip_human_only(body):
    """Drop the human-only fence; an unterminated start marker drops the rest of the body."""
    return HUMAN_ONLY.sub("", body)


def strip_tldr(body):
    """Drop the human TL;DR — from its heading to the next `---` or same-level heading."""
    lines = body.splitlines()
    kept, skipping = [], False
    for line in lines:
        if line.strip() == TLDR_HEADING:
            skipping = True
            continue
        if skipping:
            if line.strip() == "---" or re.match(r"^#{1,3} ", line):
                skipping = False
            else:
                continue
        kept.append(line)
    return "\n".join(kept)


def findings_section(body):
    """The `### Findings (for the build agent)` section only, or "" when there is none."""
    lines = body.splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if line.strip() == FINDINGS_HEADING)
    except StopIteration:
        return ""
    section = []
    for line in lines[start + 1:]:
        if line.strip() == "---" or re.match(r"^#{1,3} ", line):
            break
        section.append(line)
    return "\n".join(section).strip("\n")


def count_bullets(text):
    return sum(1 for line in text.splitlines() if TOP_LEVEL_BULLET.match(line))


def fingerprint(text):
    normalised = " ".join(text.split())
    return hashlib.sha256(normalised.encode("utf-8")).hexdigest()


def by_severity(findings):
    """Top-level bullets per bold group. Groups the body never names stay null, except
    `blockers` and `ci`, which are always a number."""
    counts = {"blockers": 0, "major": None, "minor": None, "nits": None,
              "ci": 0, "combined": None}
    current = None
    for line in findings.splitlines():
        group = BOLD_GROUP.match(line.strip())
        if group:
            label = "".join(group.group(1).split()).lower()
            current = SEVERITY_FIELDS.get(label)
            if current is not None and counts[current] is None:
                counts[current] = 0
            continue
        if current and TOP_LEVEL_BULLET.match(line):
            counts[current] += 1
    return counts


def classify(comment):
    """A verdict or fix-summary comment as a record, or None when it is neither."""
    raw = comment.get("body") or ""
    body = strip_tldr(strip_human_only(raw))
    common = {"id": comment.get("id"),
              "createdAt": comment.get("created_at"),
              "updatedAt": comment.get("updated_at")}
    if VERDICT_MARKER in body:
        approved = bool(APPROVED_VERDICT.search(body))
        sha = VERDICT_SHA.search(body)
        findings = findings_section(body)
        return {**common, "kind": "verdict", "body": body,
                "verdict": "APPROVED" if approved else "REQUEST_CHANGES",
                "reviewed": sha.group(1) if sha else None,
                "findings": None if approved else findings}
    if FIX_SUMMARY_MARKER in body:
        return {**common, "kind": "fixSummary", "body": body}
    return None


def latest(records, key=lambda record: record["updatedAt"] or ""):
    return max(records, key=key) if records else None


def latest_channel(formal_reviews, verdict):
    """The newer of the newest deciding formal review and the verdict comment, or None.
    The review wins only when strictly newer; on a tie the comment wins."""
    decided = [review for review in formal_reviews if review.get("state") in FORMAL_VERDICTS]
    formal = max(decided, key=lambda review: review.get("submitted_at") or "", default=None)
    formal_at = (formal or {}).get("submitted_at") or ""
    comment_at = (verdict or {}).get("updatedAt") or ""
    if formal and formal_at > comment_at:
        return {"channel": "review", "verdict": FORMAL_VERDICTS[formal["state"]],
                "at": formal.get("submitted_at"), "id": formal.get("id")}
    if verdict:
        return {"channel": "comment", "verdict": verdict["verdict"],
                "at": verdict["updatedAt"], "id": verdict["id"]}
    return None


repo_ref, pr, fixture = sys.argv[1], sys.argv[2], sys.argv[3]
history, reviews = sys.argv[4] == "true", sys.argv[5] == "true"

if fixture:
    with open(fixture, encoding="utf-8") as handle:
        source = json.load(handle)
    head = source.get("head")
    comments = source.get("comments", [])
    formal_reviews = source.get("reviews", [])
else:
    head = gh_json(["api", f"repos/{repo_ref}/pulls/{pr}"])["head"]["sha"]
    comments = gh_json(["api", f"repos/{repo_ref}/issues/{pr}/comments", "--paginate"])
    formal_reviews = (gh_json(["api", f"repos/{repo_ref}/pulls/{pr}/reviews", "--paginate"])
                      if reviews else [])

records = [record for record in (classify(comment) for comment in comments) if record]
verdicts = [record for record in records if record["kind"] == "verdict"]
denials = [record for record in verdicts if record["verdict"] == "REQUEST_CHANGES"]
fix_summaries = [record for record in records if record["kind"] == "fixSummary"]

latest_verdict = latest(verdicts)
latest_denial = latest(denials)

# A fix summary counts only when it is newer than the denial it would have addressed.
if latest_denial:
    addressed = [record for record in fix_summaries
                 if (record["updatedAt"] or "") > (latest_denial["updatedAt"] or "")]
else:
    addressed = fix_summaries
latest_fix = latest(addressed)

state = {
    "head": head,
    "verdict": None if not latest_verdict else {
        "id": latest_verdict["id"],
        "verdict": latest_verdict["verdict"],
        "reviewed": latest_verdict["reviewed"],
        "atHead": bool(head and latest_verdict["reviewed"]
                       and head.startswith(latest_verdict["reviewed"])),
        "createdAt": latest_verdict["createdAt"],
        "updatedAt": latest_verdict["updatedAt"],
    },
    "denial": None if not latest_denial else {
        "id": latest_denial["id"],
        "reviewed": latest_denial["reviewed"],
        "createdAt": latest_denial["createdAt"],
        "updatedAt": latest_denial["updatedAt"],
        "findings": latest_denial["findings"],
        "count": count_bullets(latest_denial["findings"]),
        "fingerprint": fingerprint(latest_denial["findings"]),
        "bySeverity": by_severity(latest_denial["findings"]),
    },
    "fixSummary": None if not latest_fix else {
        "id": latest_fix["id"],
        "createdAt": latest_fix["createdAt"],
        "updatedAt": latest_fix["updatedAt"],
        "body": latest_fix["body"],
    },
    "rounds": {"verdicts": len(verdicts), "denials": len(denials),
               "fixSummaries": len(fix_summaries)},
}

if history:
    state["history"] = [
        {"kind": record["kind"], "id": record["id"],
         "verdict": record.get("verdict"), "reviewed": record.get("reviewed"),
         "createdAt": record["createdAt"], "updatedAt": record["updatedAt"],
         "findings": record.get("findings"), "body": record["body"]}
        for record in sorted(records, key=lambda record: record["createdAt"] or "")
    ]

if reviews:
    newest = latest_channel(formal_reviews, state["verdict"])
    newest_at = (newest or {}).get("at") or ""
    state["latest"] = newest
    state["fixNeeded"] = bool(
        newest and newest["verdict"] == "REQUEST_CHANGES"
        and not any((record["updatedAt"] or "") > newest_at for record in fix_summaries))

print(json.dumps(state, indent=1))
