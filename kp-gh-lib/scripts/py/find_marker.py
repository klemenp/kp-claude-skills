import argparse
import json
import re
import subprocess
import sys

PER_PAGE = 100
# A loosely matched start marker up to its end marker, or to the end of an unclosed body.
HUMAN_ONLY_FENCE = re.compile(
    r"<!--\s*human-only:start.*?(?:<!--\s*human-only:end\s*-->|\Z)", re.S)
DETAILS_TAG = re.compile(r"<(/?)details\b[^>]*>", re.I)
SHORT_REF = re.compile(r"#(\d+)")
FULL_REF = re.compile(r"([\w.-]+/[\w.-]+)#(\d+)")
REPO = re.compile(r"[^/\s]+/[^/\s]+")
HTML_COMMENT_LINE = re.compile(r"<!--(.*)-->")


class UsageError(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError(message)


def parse_args(argv):
    parser = Parser(prog="find-marker.sh", add_help=False)
    parser.add_argument("positional", nargs="+")
    parser.add_argument("--state", choices=("open", "closed", "all"), default="open")
    parser.add_argument("--label", action="append", default=[])
    parser.add_argument("--scope", choices=("repo", "owner"), default="repo")
    parser.add_argument("--any-value", action="store_true")
    parser.add_argument("--comments", action="store_true")
    parser.add_argument("--from-file")
    args = parser.parse_args(argv)
    expected = 2 if args.any_value else 3
    if len(args.positional) != expected:
        raise UsageError(f"expected {expected} positional arguments, got {len(args.positional)}")
    args.repo, args.marker = args.positional[:2]
    args.value = None if args.any_value else args.positional[2]
    if not REPO.fullmatch(args.repo):
        raise UsageError(f"not an owner/repo: {args.repo!r}")
    if not args.marker.strip() or "\n" in args.marker:
        raise UsageError("empty or multi-line marker")
    if args.value is not None and (not args.value.strip() or "\n" in args.value):
        raise UsageError("empty or multi-line value")
    return args


def fail(message):
    print(f"find-marker.sh: {message}", file=sys.stderr)
    sys.exit(1)


def run(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"{' '.join(command)} failed: {result.stderr.strip()}")
    return result.stdout


def gh_pages(path, params):
    command = ["gh", "api", "-X", "GET", path, "--paginate", "--slurp"]
    for key, value in params.items():
        command += ["-f", f"{key}={value}"]
    return json.loads(run(command))


def visible_text(body):
    """The body with the human-only fence and every <details> block cut out. A cut leaves a
    line break, so text on either side of it never fuses into one line."""
    text = HUMAN_ONLY_FENCE.sub("\n", (body or "").replace("\r\n", "\n"))
    kept, depth, position = [], 0, 0
    for tag in DETAILS_TAG.finditer(text):
        if depth == 0:
            kept.append(text[position:tag.start()])
        if tag.group(1):
            depth = max(depth - 1, 0)
        else:
            depth += 1
        position = tag.end()
        if depth == 0:
            kept.append("\n")
    if depth == 0:
        kept.append(text[position:])
    return "".join(kept)


def as_reference(value, hit_repo):
    """`owner/repo#n` for either reference form, or None for any other value."""
    if SHORT_REF.fullmatch(value):
        return f"{hit_repo}#{value[1:]}"
    if FULL_REF.fullmatch(value):
        return value
    return None


def value_matches(found, args, hit_repo):
    if args.any_value or found == args.value:
        return True
    if SHORT_REF.fullmatch(args.value):
        wanted = f"{args.repo}#{args.value[1:]}"
        return hit_repo == args.repo and as_reference(found, hit_repo) == wanted
    if FULL_REF.fullmatch(args.value):
        return as_reference(found, hit_repo) == args.value
    return False


def confirmed_values(body, args, hit_repo):
    prefix = f"{args.marker}: "
    values = []
    for line in visible_text(body).split("\n"):
        line = line.strip()
        wrapped = HTML_COMMENT_LINE.fullmatch(line)
        if wrapped:
            line = wrapped.group(1).strip()
        if not line.startswith(prefix):
            continue
        found = line[len(prefix):]
        if found and value_matches(found, args, hit_repo) and found not in values:
            values.append(found)
    return values


def search_phrases(args):
    if args.any_value:
        return [f"{args.marker}:"]
    phrases = [f"{args.marker}: {args.value}"]
    if SHORT_REF.fullmatch(args.value):
        phrases.append(f"{args.marker}: {args.repo}#{args.value[1:]}")
    elif FULL_REF.fullmatch(args.value):
        phrases.append(f"{args.marker}: #{args.value.split('#')[1]}")
    return phrases


def search(args, where):
    # `user:` matches an organization's repos too (probed), so one owner query suffices.
    scope = f"repo:{args.repo}" if args.scope == "repo" else f"user:{args.repo.split('/')[0]}"
    qualifiers = [scope, "is:issue", f"in:{'comments' if where == 'comment' else 'body'}"]
    if args.state != "all":
        qualifiers.append(f"is:{args.state}")
    qualifiers += [f'label:"{label}"' for label in args.label]
    hits = {}
    for phrase in search_phrases(args):
        query = " ".join([json.dumps(phrase)] + qualifiers)
        for page in gh_pages("search/issues", {"q": query, "per_page": PER_PAGE}):
            for item in page["items"]:
                repo = item["repository_url"].split("/repos/", 1)[1]
                hits[(repo, item["number"])] = {
                    "number": item["number"], "repo": repo, "state": item["state"],
                    "labels": [label["name"] for label in item["labels"]],
                    "url": item["html_url"], "body": item["body"]}
    return list(hits.values())


def comments_of(issue):
    pages = gh_pages(f"repos/{issue['repo']}/issues/{issue['number']}/comments",
                     {"per_page": PER_PAGE})
    return [{"id": comment["id"], "body": comment["body"]} for page in pages for comment in page]


def in_filters(issue, args):
    """The search's own filters, applied to --from-file fixtures so they behave like one."""
    owner = args.repo.split("/")[0]
    if args.scope == "repo" and issue["repo"] != args.repo:
        return False
    if args.scope == "owner" and issue["repo"].split("/")[0] != owner:
        return False
    if args.state != "all" and issue["state"].lower() != args.state:
        return False
    return set(args.label) <= set(issue["labels"])


def entry(issue, value, where, comment_id):
    return {"number": issue["number"], "repo": issue["repo"], "state": issue["state"].upper(),
            "labels": issue["labels"], "url": issue["url"], "value": value,
            "where": where, "commentId": comment_id}


def find(args):
    if args.from_file:
        with open(args.from_file) as fixture:
            issues = json.load(fixture)["issues"]
        body_hits = comment_hits = [issue for issue in issues if in_filters(issue, args)]
    else:
        body_hits = search(args, "body")
        comment_hits = search(args, "comment") if args.comments else []
    results = []
    for issue in body_hits:
        results += [entry(issue, value, "body", None)
                    for value in confirmed_values(issue["body"], args, issue["repo"])]
    if not args.comments:
        return results
    for issue in comment_hits:
        comments = issue["comments"] if args.from_file else comments_of(issue)
        for comment in comments:
            results += [entry(issue, value, "comment", comment["id"])
                        for value in confirmed_values(comment["body"], args, issue["repo"])]
    return results


try:
    arguments = parse_args(sys.argv[1:])
except UsageError as error:
    print(f"find-marker.sh: {error}", file=sys.stderr)
    print("usage: find-marker.sh <owner/repo> <marker> (<value> | --any-value)"
          " [--state open|closed|all] [--label <name>]… [--scope repo|owner] [--comments]"
          " [--from-file <json>]", file=sys.stderr)
    sys.exit(2)
print(json.dumps(find(arguments)))
