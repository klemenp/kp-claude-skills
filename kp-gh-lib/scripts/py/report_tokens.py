import glob
import json
import os
import re
import sys

(start, marker, transcript_arg, comments_path, body_path,
 out_body, out_id) = sys.argv[1:8]

KEYS = ("input_tokens", "output_tokens", "cache_creation_input_tokens",
        "cache_read_input_tokens")
COLUMNS = ("run start (UTC)", "model", "effort", "input", "output", "cache write",
           "cache read", "subagents", "total")
# The first TEXT_CELLS cells are text and round-trip unchanged; the rest are figures.
TEXT_CELLS = 3
# The 7-column table written before `effort` and `subagents` existed.
OLD_COLUMNS = ["run start (UTC)", "model", "input", "output", "cache write",
               "cache read", "total"]
EFFORTS = ("low", "medium", "high", "xhigh", "max")
NO_EFFORT = "\u2014"
MAX_ROWS = 100
UNKNOWN = "?"
# The pre-2026-09 single-line comment, converted into the table's first row.
OLD_LINE = re.compile(r"^\*\*Token usage \(this skill run\)\*\*")
OLD_FIGURES = re.compile(
    r"input: (\d+), output: (\d+), cache write: (\d+), cache read: (\d+)")
DROPPED = re.compile(r"(\d+) oldest rows? dropped")


def newest(pattern):
    paths = glob.glob(pattern)
    return max(paths, key=os.path.getmtime) if paths else None


def transcript_path():
    # A named transcript (--render) is used or missing, never swapped for a live one.
    if transcript_arg.endswith(".jsonl"):
        return transcript_arg if os.path.isfile(transcript_arg) else None
    return newest(os.path.join(transcript_arg, "*.jsonl")) or newest(
        os.path.expanduser("~/.claude/projects/*/*.jsonl"))


def measure(path):
    """This run's (model, four figures) from a transcript, None if unreadable."""
    if path is None:
        return None
    totals = dict.fromkeys(KEYS, 0)
    models = set()
    seen_ids = set()
    try:
        transcript = open(path, encoding="utf-8")
    except OSError:
        return None
    with transcript:
        for line in transcript:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            # ISO-8601 UTC compares lexicographically, so a string >= filter is exact.
            if entry.get("type") != "assistant" or entry.get("timestamp", "") < start:
                continue
            message = entry.get("message") or {}
            if message.get("model"):
                models.add(message["model"])
            # One response spans several entries (one per content block) sharing
            # message.id and repeating the same usage; count it once. An entry with
            # no id is always counted, never deduped against another id-less entry.
            message_id = message.get("id")
            if message_id is not None:
                if message_id in seen_ids:
                    continue
                seen_ids.add(message_id)
            usage = message.get("usage") or {}
            for key in KEYS:
                totals[key] += usage.get(key, 0)
    return "+".join(sorted(models)) or UNKNOWN, [totals[key] for key in KEYS]


def subagent_total(path):
    """The four figures summed over the session's subagent transcripts since the run
    start, each file measured like the top-level one; None with no resolved transcript."""
    if path is None:
        return None
    directory = os.path.join(path[:-len(".jsonl")], "subagents")
    total = 0
    for agent_path in sorted(glob.glob(os.path.join(directory, "agent-*.jsonl"))):
        measured = measure(agent_path)
        if measured is not None:
            total += sum(measured[1])
    return total


def effort():
    value = os.environ.get("KP_EFFORT", "")
    return value if value in EFFORTS else NO_EFFORT


def marked_comment():
    """The (id, body) of the marked comment, or (None, "") when there is none."""
    if comments_path:
        with open(comments_path, encoding="utf-8") as handle:
            for comment in json.load(handle):
                if marker in (comment.get("body") or ""):
                    return comment["id"], comment["body"]
    elif body_path and os.path.isfile(body_path):
        with open(body_path, encoding="utf-8") as handle:
            return None, handle.read()
    return None, ""


def number(cell):
    try:
        return int(cell.replace(",", ""))
    except ValueError:
        return None


def parse(body):
    """The rows already in the comment, and how many were dropped before now."""
    rows, dropped = [], 0
    old_table = False
    for line in body.splitlines():
        line = line.strip()
        if not line.startswith("|"):
            if OLD_LINE.match(line):
                found = OLD_FIGURES.search(line)
                figures = [int(n) for n in found.groups()] if found else [None] * 4
                total = sum(figures) if found else None
                rows.append([UNKNOWN] * TEXT_CELLS + figures + [None, total])
            continue
        parts = [cell.strip() for cell in line.strip("|").split("|")]
        if parts == OLD_COLUMNS:
            old_table = True
            continue
        if old_table and len(parts) == len(OLD_COLUMNS):
            # Insert `?` for effort (third cell) and subagents (before total).
            parts = parts[:2] + [UNKNOWN] + parts[2:6] + [UNKNOWN] + parts[6:]
        if len(parts) != len(COLUMNS):
            continue
        if parts[0].startswith("**Sum**"):
            found = DROPPED.search(parts[0])
            dropped = int(found.group(1)) if found else 0
            continue
        # The header and its `| --- |` separator carry no figures.
        if parts[0] == COLUMNS[0] or set(parts[0]) <= set("-: "):
            continue
        rows.append(parts[:TEXT_CELLS] + [number(cell) for cell in parts[TEXT_CELLS:]])
    return rows, dropped


def cell(value):
    return UNKNOWN if value is None else format(value, ",")


def render(values):
    return "| " + " | ".join(values) + " |"


def render_row(row):
    return render(row[:TEXT_CELLS] + [cell(value) for value in row[TEXT_CELLS:]])


path = transcript_path()
measured = measure(path)
if measured is None:
    run_row = [start, UNKNOWN, effort(), None, None, None, None, None, None]
else:
    model, figures = measured
    run_row = [start, model, effort()] + figures + [subagent_total(path), sum(figures)]

comment_id, body = marked_comment()
rows, dropped = parse(body)
if start in (row[0] for row in rows):
    rows = [run_row if row[0] == start else row for row in rows]
else:
    rows.append(run_row)
if len(rows) > MAX_ROWS:
    dropped += len(rows) - MAX_ROWS
    rows = rows[-MAX_ROWS:]


def column_sum(index):
    values = [row[index] for row in rows if isinstance(row[index], int)]
    return sum(values) if values else None


def plural(count, noun):
    return f"{count} {noun}" + ("" if count == 1 else "s")


label = "**Sum** (" + plural(len(rows), "run")
if dropped:
    label += "; " + plural(dropped, "oldest row") + " dropped"
label += ")"

lines = [marker, "",
         "**Token usage — one row per run.** "
         "Format: `kp-gh-lib/NOTES.md` § *Token-usage report*.", "",
         render(COLUMNS), render(["---"] * len(COLUMNS))]
lines += [render_row(row) for row in rows]
lines.append(render([label, "", ""] + [cell(column_sum(i))
                                       for i in range(TEXT_CELLS, len(COLUMNS))]))

with open(out_body, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
with open(out_id, "w", encoding="utf-8") as handle:
    handle.write("" if comment_id is None else str(comment_id))
print(render_row(run_row))
