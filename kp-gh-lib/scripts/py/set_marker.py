import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

# The same fence, <details> and reference rules as find-marker.sh.
HUMAN_ONLY_FENCE = re.compile(
    r"<!--\s*human-only:start.*?(?:<!--\s*human-only:end\s*-->|\Z)", re.S)
DETAILS_TAG = re.compile(r"<(/?)details\b[^>]*>", re.I)
SHORT_REF = re.compile(r"#(\d+)")
FULL_REF = re.compile(r"([\w.-]+/[\w.-]+)#(\d+)")
REPO = re.compile(r"[^/\s]+/[^/\s]+")
ISSUE_NUMBER = re.compile(r"[1-9]\d*")
HTML_COMMENT_LINE = re.compile(r"<!--(.*)-->")
# A `<word>: <text>` marker line, bare or wrapped in an HTML comment.
ANY_MARKER_LINE = re.compile(r"(?:<!--\s*)?[\w.-]+: \S.*")


class UsageError(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError(message)


def parse_args(argv):
    parser = Parser(prog="set-marker.sh", add_help=False)
    parser.add_argument("repo")
    parser.add_argument("number")
    parser.add_argument("marker")
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--add", metavar="VALUE")
    action.add_argument("--replace", nargs=2, metavar=("OLD", "NEW"))
    action.add_argument("--remove", metavar="VALUE")
    parser.add_argument("--from-file")
    args = parser.parse_args(argv)
    if not REPO.fullmatch(args.repo):
        raise UsageError(f"not an owner/repo: {args.repo!r}")
    if not ISSUE_NUMBER.fullmatch(args.number):
        raise UsageError(f"not a positive issue number: {args.number!r}")
    values = [args.marker] + [v for v in (args.add, args.remove) if v is not None]
    values += args.replace or []
    for value in values:
        if not value.strip() or "\n" in value or "\r" in value:
            raise UsageError("empty or multi-line marker or value")
    return args


def fail(message):
    print(f"set-marker.sh: {message}", file=sys.stderr)
    sys.exit(1)


def run(command):
    # Bytes, decoded by hand: text mode would translate the body's "\r\n" line endings.
    result = subprocess.run(command, capture_output=True)
    if result.returncode != 0:
        stderr = result.stderr.decode("utf-8", "replace").strip()
        fail(f"{' '.join(command)} failed: {stderr}")
    return result.stdout.decode("utf-8")


def fenced_spans(body):
    """(start, end) offsets of the human-only fences and top-level <details> blocks."""
    spans = [match.span() for match in HUMAN_ONLY_FENCE.finditer(body)]

    def in_fence(offset):
        return any(start <= offset < end for start, end in spans)

    details, depth, opened = [], 0, 0
    for tag in DETAILS_TAG.finditer(body):
        if in_fence(tag.start()):
            continue
        if tag.group(1):
            if depth == 1:
                details.append((opened, tag.end()))
            depth = max(depth - 1, 0)
        else:
            if depth == 0:
                opened = tag.start()
            depth += 1
    if depth > 0:
        details.append((opened, len(body)))
    return spans + details


def split_lines(body):
    """[(text, start offset)] for each line of the body split on "\n"; a trailing "\r"
    stays on its line, so joining the texts with "\n" gives the body back unchanged."""
    lines, offset = [], 0
    for text in body.split("\n"):
        lines.append((text, offset))
        offset += len(text) + 1
    return lines


def eligible(line, spans):
    text, start = line
    end = start + len(text)
    return not any(span_start < end + 1 and start < span_end
                   for span_start, span_end in spans)


def unwrap(text):
    """(content, is_comment) of a trimmed line, unwrapping a whole <!-- … --> line."""
    stripped = text.strip()
    wrapped = HTML_COMMENT_LINE.fullmatch(stripped)
    if wrapped:
        return wrapped.group(1).strip(), True
    return stripped, False


def as_reference(value, repo):
    if SHORT_REF.fullmatch(value):
        return f"{repo}#{value[1:]}"
    if FULL_REF.fullmatch(value):
        return value
    return None


def same_value(found, wanted, repo):
    if found == wanted:
        return True
    reference = as_reference(wanted, repo)
    return reference is not None and as_reference(found, repo) == reference


def marker_value(text, marker):
    """The value of a `<marker>: <value>` line, '' for a bare `<marker>:`, else None."""
    content, _ = unwrap(text)
    if content == f"{marker}:":
        return ""
    prefix = f"{marker}: "
    return content[len(prefix):] if content.startswith(prefix) else None


def matches(line, marker, wanted, repo):
    found = marker_value(line[0], marker)
    return bool(found) and same_value(found, wanted, repo)


def rewritten(text, marker, value):
    """`text` with its marker value replaced, keeping indentation, form and a "\r"."""
    indent = text[:len(text) - len(text.lstrip())]
    carriage = "\r" if text.endswith("\r") else ""
    _, is_comment = unwrap(text)
    line = f"{marker}: {value}"
    return f"{indent}{'<!-- ' + line + ' -->' if is_comment else line}{carriage}"


def appended(body, line):
    eol = "\r\n" if "\r\n" in body else "\n"
    if not body.strip():
        return body + line + (eol if body.endswith("\n") else "")
    ends_with_newline = body.endswith("\n")
    text = body if ends_with_newline else body + eol
    last_lines = text.split("\n")
    last_non_empty = next(part.strip() for part in reversed(last_lines) if part.strip())
    already_blank = last_lines[-2].strip() == ""
    if not ANY_MARKER_LINE.fullmatch(last_non_empty) and not already_blank:
        text += eol
    return text + line + (eol if ends_with_newline else "")


def add(body, lines, flags, args):
    if any(ok and matches(line, args.marker, args.add, args.repo)
           for line, ok in zip(lines, flags)):
        return body
    anchors = [index for index, (line, ok) in enumerate(zip(lines, flags))
               if ok and marker_value(line[0], args.marker) is not None]
    new_line = f"{args.marker}: {args.add}"
    if not anchors:
        return appended(body, new_line)
    anchor = anchors[-1]
    texts = [text for text, _ in lines]
    carriage = "\r" if texts[anchor].endswith("\r") else ""
    texts.insert(anchor + 1, new_line + carriage)
    return "\n".join(texts)


def replace(body, lines, flags, args):
    old, new = args.replace
    if same_value(old, new, args.repo):
        return body
    new_present = any(ok and matches(line, args.marker, new, args.repo)
                      for line, ok in zip(lines, flags))
    texts = []
    for line, ok in zip(lines, flags):
        if not (ok and matches(line, args.marker, old, args.repo)):
            texts.append(line[0])
        elif not new_present:
            texts.append(rewritten(line[0], args.marker, new))
    return "\n".join(texts)


def remove(body, lines, flags, args):
    return "\n".join(line[0] for line, ok in zip(lines, flags)
                     if not (ok and matches(line, args.marker, args.remove, args.repo)))


def edited(body, args):
    lines = split_lines(body)
    spans = fenced_spans(body)
    flags = [eligible(line, spans) for line in lines]
    if args.add is not None:
        return add(body, lines, flags, args)
    if args.replace is not None:
        return replace(body, lines, flags, args)
    return remove(body, lines, flags, args)


def read_body(args):
    if args.from_file:
        with open(args.from_file, newline="") as fixture:
            return json.load(fixture)["body"]
    output = run(["gh", "issue", "view", args.number, "-R", args.repo,
                  "--json", "body", "--jq", ".body"])
    # --jq prints the string followed by one newline that is not part of the body.
    return output[:-1] if output.endswith("\n") else output


def write_body(args, body):
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, newline="") as handle:
        handle.write(body)
        path = handle.name
    try:
        run(["gh", "issue", "edit", args.number, "-R", args.repo, "--body-file", path])
    finally:
        os.unlink(path)


try:
    arguments = parse_args(sys.argv[1:])
except UsageError as error:
    print(f"set-marker.sh: {error}", file=sys.stderr)
    print("usage: set-marker.sh <owner/repo> <n> <marker>"
          " (--add <value> | --replace <old> <new> | --remove <value>)"
          " [--from-file <json>]", file=sys.stderr)
    sys.exit(2)

original = read_body(arguments)
result = edited(original, arguments)
changed = result != original
if arguments.from_file:
    print(json.dumps({"changed": changed, "body": result}))
    sys.exit(0)
if changed:
    write_body(arguments, result)
print(json.dumps({"changed": changed}))
